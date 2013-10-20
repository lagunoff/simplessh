module Network.SSH.Client.SimpleSSH
  ( SimpleSSHError(..)
  , SimpleSSH
  , Session
  , Result(..)
  , runSimpleSSH
  , openSession
  , authenticateWithPassword
  , authenticateWithKey
  , execCommand
  , sendFile
  , closeSession
  , withSessionPassword
  , withSessionKey
  ) where

import           Control.Applicative
import           Control.Monad.Error

import qualified Data.ByteString.Char8 as BS

import           Foreign.C.String
import           Foreign.Marshal.Alloc
import           Foreign.Ptr

import           Network.SSH.Client.SimpleSSH.Foreign
import           Network.SSH.Client.SimpleSSH.Types

getValue :: CEither -> (Ptr () -> b) -> IO b
getValue eitherC build = build <$> getValueC eitherC

getError :: CEither -> IO SimpleSSHError
getError eitherC = readError <$> getErrorC eitherC

getContent :: CResult -> IO BS.ByteString
getContent ptr = BS.packCString =<< getContentC ptr

getExitCode :: CResult -> IO Integer
getExitCode ptr = toInteger <$> getExitCodeC ptr

readResult :: CResult -> IO Result
readResult resultC =  Result <$> getContent resultC <*> getExitCode resultC

readCount :: CCount -> IO Integer
readCount countC = toInteger <$> getCountC countC

-- | Helper which lifts IO actions into 'SimpleSSH'. This is used all over the place.
liftIOEither :: IO (Either SimpleSSHError a) -> SimpleSSH a
liftIOEither ioAction = do
  eRes <- liftIO ioAction
  case eRes of
    Left err  -> throwError err
    Right res -> return res

-- | Helper which interprets a result coming from C.
--
-- Functions in the C part return pointers to a structure mimicking 'Either'.
liftEitherCFree :: (CEither -> IO ()) -- ^ A custom function to free the CEither
                -> (Ptr () -> a)      -- ^ A function to transform the pointer contained in the C structure
                -> IO CEither         -- ^ An action returning the structure, typically a call to C
                -> IO (Either SimpleSSHError a)
liftEitherCFree customFree constr action = do
  eitherC   <- action
  checkLeft <- isLeftC eitherC
  res <- if checkLeft == 0
    then Right <$> getValue eitherC constr
    else Left  <$> getError eitherC
  customFree eitherC
  return res

-- | Version of 'liftEitherCFree' using the normal 'free'.
liftEitherC :: (Ptr () -> a) -> IO CEither -> IO (Either SimpleSSHError a)
liftEitherC = liftEitherCFree free

-- | Open a SSH session. The next step is to authenticate.
openSession :: String  -- ^ Hostname
            -> Integer -- ^ Port
            -> String  -- ^ Path to the known hosts (e.g. ~/.ssh/known_hosts)
            -> SimpleSSH Session
openSession hostname port knownhostsPath = liftIOEither $ do
  hostnameC       <- newCString hostname
  knownhostsPathC <- newCString knownhostsPath
  let portC = fromInteger port

  res <- liftEitherC Session $ openSessionC hostnameC portC knownhostsPathC

  free hostnameC
  free knownhostsPathC

  return res

-- | Authenticate a session with a pair username / password.
authenticateWithPassword :: Session -- ^ Session to use
                         -> String  -- ^ Username
                         -> String  -- ^ Password
                         -> SimpleSSH Session
authenticateWithPassword session username password = liftIOEither $ do
  usernameC <- newCString username
  passwordC <- newCString password

  res <- liftEitherC Session $ authenticatePasswordC session usernameC passwordC

  free usernameC
  free passwordC

  return res

-- ^ Authenticate with a public key for a given username.
--
-- Leave the passphrase empty if not needed.
authenticateWithKey :: Session  -- ^ Session to use
                    -> String   -- ^ Username
                    -> FilePath -- ^ Path to the public key (e.g. ~/.ssh/id_rsa.pub)
                    -> FilePath -- ^ Path to the private key (e.g. ~/.ssh/id_rsa)
                    -> String   -- ^ Passphrase
                    -> SimpleSSH Session
authenticateWithKey session username publicKeyPath privateKeyPath passphrase = liftIOEither $ do
  (usernameC, publicKeyPathC, privateKeyPathC, passphraseC) <-
    (,,,) <$> newCString username
          <*> newCString publicKeyPath
          <*> newCString privateKeyPath
          <*> newCString passphrase

  res <- liftEitherC Session $ authenticateKeyC session usernameC publicKeyPathC privateKeyPathC passphraseC

  mapM_ free [usernameC, publicKeyPathC, privateKeyPathC, passphraseC]

  return res

-- | Send a command to the server.
--
-- One should be authenticated before sending commands on a 'Session'.
execCommand :: Session -- ^ Session to use
            -> String  -- ^ Command
            -> SimpleSSH Result
execCommand session command = do
  result <- liftIOEither $ do
    commandC <- newCString command
    res      <- liftEitherCFree freeEitherResultC CResult $ execCommandC session commandC
    free commandC
    return res
  liftIO $ readResult result

-- | Send a file to the server and returns the number of bytes transferred.
--
-- One should be authenticated before sending files on a 'Session.
sendFile :: Session -- ^ Session to use
         -> Integer -- ^ File mode (e.g. 0o777, note the octal notation)
         -> String  -- ^ Source path
         -> String  -- ^ Target path
         -> SimpleSSH Integer
sendFile session mode source target = do
  count <- liftIOEither $ do
    sourceC <- newCString source
    targetC <- newCString target
    let modeC = fromInteger mode

    res <- liftEitherCFree freeEitherCountC CCount $ sendFileC session modeC sourceC targetC

    free sourceC
    free targetC

    return res

  liftIO $ readCount count

-- | Close a session.
closeSession :: Session -> SimpleSSH ()
closeSession = lift . closeSessionC

-- | Open a connection, authenticate, execute some action and close the connection.
--
-- It is the safe way of using SimpleSSH. This function is to be used to authenticate with a pair username / password, otherwise see 'withSessionKey'.
withSessionPassword :: String                   -- ^ Hostname
                    -> Integer                  -- ^ Port
                    -> String                   -- ^ Path to known_hosts
                    -> String                   -- ^ Username
                    -> String                   -- ^ Password
                    -> (Session -> SimpleSSH a) -- ^ Monadic action on the session
                    -> SimpleSSH a
withSessionPassword hostname port knownhostsPath username password action = do
  session              <- openSession hostname port knownhostsPath
  authenticatedSession <- authenticateWithPassword session username password
  res                  <- action authenticatedSession
  closeSession authenticatedSession
  return res

-- | Open a connection, authenticate, execute some action and close the connection.
--
-- It is the safe way of using SimpleSSH. This function is to be used to authenticate with a key, otherwise see 'withSessionPassword'.
withSessionKey :: String                   -- ^ Hostname
               -> Integer                  -- ^ port
               -> String                   -- ^ Path to known_hosts
               -> String                   -- ^ Username
               -> String                   -- ^ Path to public key
               -> String                   -- ^ Path to private key
               -> String                   -- ^ Passphrase
               -> (Session -> SimpleSSH a) -- ^ Monadic action on the session
               -> SimpleSSH a
withSessionKey hostname port knownhostsPath username publicKeyPath privateKeyPath passphrase action = do
  session              <- openSession hostname port knownhostsPath
  authenticatedSession <- authenticateWithKey session username publicKeyPath privateKeyPath passphrase
  res                  <- action authenticatedSession
  closeSession authenticatedSession
  return res