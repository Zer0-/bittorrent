-- |
--   Module      :  Network.BitTorrent.Exchange.Wire
--   Copyright   :  (c) Sam Truzjan 2013
--                  (c) Daniel Gröber 2013
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   This module control /integrity/ of data send and received.
--
{-# LANGUAGE DeriveDataTypeable #-}
module Network.BitTorrent.Exchange.Wire
       ( -- * Wire
         Wire

         -- ** Exceptions
       , ChannelSide   (..)
       , ProtocolError (..)
       , WireFailure   (..)
       , peerPenalty
       , isWireFailure
       , disconnectPeer

         -- ** Stats
       , ByteStats       (..)
       , FlowStats       (..)
       , ConnectionStats (..)

         -- ** Flood detection
       , FloodDetector   (..)

         -- ** Options
       , Options         (..)

         -- ** Connection
       , Connection
       , connProtocol
       , connCaps
       , connTopic
       , connRemotePeerId
       , connThisPeerId
       , connOptions

         -- ** Setup
       , runWire
       , connectWire
       , acceptWire

         -- ** Messaging
       , recvMessage
       , sendMessage

         -- ** Query
       , getConnection
       , getExtCaps
       , getStats
       ) where

import Control.Applicative
import Control.Exception
import Control.Monad.Reader
import Data.ByteString as BS
import Data.Conduit
import Data.Conduit.Cereal
import Data.Conduit.List
import Data.Conduit.Network
import Data.Default
import Data.IORef
import Data.Maybe
import Data.Monoid
import Data.Serialize as S
import Data.Typeable
import Network
import Network.Socket
import Network.Socket.ByteString as BS
import Text.PrettyPrint as PP hiding (($$), (<>))
import Text.PrettyPrint.Class
import Text.Show.Functions

import Data.Torrent.InfoHash
import Network.BitTorrent.Core
import Network.BitTorrent.Exchange.Message
import Data.Torrent
import Data.Torrent.Piece
import Data.BEncode as BE

-- TODO handle port message?
-- TODO handle limits?
-- TODO filter not requested PIECE messages
-- TODO metadata piece request flood protection
-- TODO piece request flood protection
-- TODO protect against flood attacks
{-----------------------------------------------------------------------
--  Exceptions
-----------------------------------------------------------------------}

-- | Used to specify initiator of 'ProtocolError'.
data ChannelSide
  = ThisPeer
  | RemotePeer
    deriving (Show, Eq, Enum, Bounded)

instance Default ChannelSide where
  def = ThisPeer

instance Pretty ChannelSide where
  pretty = PP.text . show

-- | A protocol errors occur when a peer violates protocol
-- specification.
data ProtocolError
    -- | Protocol string should be 'BitTorrent Protocol' but remote
    -- peer have sent a different string.
  = InvalidProtocol   ProtocolName

    -- | Sent and received protocol strings do not match. Can occur
    -- in 'connectWire' only.
  | UnexpectedProtocol ProtocolName

    -- | /Remote/ peer replied with invalid 'hsInfoHash' which do not
    -- match with 'hsInfoHash' /this/ peer have sent. Can occur in
    -- 'connectWire' only.
  | UnexpectedTopic   InfoHash

    -- | Some trackers or DHT can return 'PeerId' of a peer. If a
    -- remote peer handshaked with different 'hsPeerId' then this
    -- exception is raised. Can occur in 'connectWire' only.
  | UnexpectedPeerId  PeerId

    -- | Accepted peer have sent unknown torrent infohash in
    -- 'hsInfoHash' field. This situation usually happen when /this/
    -- peer have deleted the requested torrent. The error can occur in
    -- 'acceptWire' function only.
  | UnknownTopic      InfoHash

    -- | A remote peer have 'ExtExtended' enabled but did not send an
    -- 'ExtendedHandshake' back.
  | HandshakeRefused

    -- | 'Network.BitTorrent.Exchange.Message.Bitfield' message MUST
    -- be send either once or zero times, but either this peer or
    -- remote peer send a bitfield message the second time.
  | BitfieldAlreadySent ChannelSide

    -- | Capabilities violation. For example this exception can occur
    -- when a peer have sent 'Port' message but 'ExtDHT' is not
    -- allowed in 'connCaps'.
  | DisallowedMessage
    { -- | Who sent invalid message.
      violentSender     :: ChannelSide

      -- | If the 'violentSender' reconnect with this extension
      -- enabled then he can try to send this message.
    , extensionRequired :: Extension
    }
    deriving Show

instance Pretty ProtocolError where
  pretty = PP.text . show

errorPenalty :: ProtocolError -> Int
errorPenalty (InvalidProtocol      _) = 1
errorPenalty (UnexpectedProtocol   _) = 1
errorPenalty (UnexpectedTopic      _) = 1
errorPenalty (UnexpectedPeerId     _) = 1
errorPenalty (UnknownTopic         _) = 0
errorPenalty (HandshakeRefused      ) = 1
errorPenalty (BitfieldAlreadySent  _) = 1
errorPenalty (DisallowedMessage  _ _) = 1

-- | Exceptions used to interrupt the current P2P session.
data WireFailure
    -- | Force termination of wire connection.
    --
    --   Normally you should throw only this exception from event loop
    --   using 'disconnectPeer', other exceptions are thrown
    --   automatically by functions from this module.
    --
  = DisconnectPeer

     -- | A peer not responding and did not send a 'KeepAlive' message
     -- for a specified period of time.
  | PeerDisconnected

    -- | A remote peer have sent some unknown message we unable to
    -- parse.
  | DecodingError GetException

    -- | See 'ProtocolError' for more details.
  | ProtocolError ProtocolError

    -- | A possible malicious peer have sent too many control messages
    -- without making any progress.
  | FloodDetected ConnectionStats
    deriving (Show, Typeable)

instance Exception WireFailure

instance Pretty WireFailure where
  pretty = PP.text . show

-- TODO
-- data Penalty = Ban | Penalty Int

peerPenalty :: WireFailure -> Int
peerPenalty  DisconnectPeer   = 0
peerPenalty  PeerDisconnected = 0
peerPenalty (DecodingError _) = 1
peerPenalty (ProtocolError e) = errorPenalty e
peerPenalty (FloodDetected _) = 1

-- | Do nothing with exception, used with 'handle' or 'try'.
isWireFailure :: Monad m => WireFailure -> m ()
isWireFailure _ = return ()

protocolError :: MonadThrow m => ProtocolError -> m a
protocolError = monadThrow . ProtocolError

-- | Forcefully terminate wire session and close socket.
disconnectPeer :: Wire a
disconnectPeer = monadThrow DisconnectPeer

{-----------------------------------------------------------------------
--  Stats
-----------------------------------------------------------------------}

-- | Message stats in one direction.
data FlowStats = FlowStats
  { -- | Number of the messages sent or received.
    messageCount :: {-# UNPACK #-} !Int
    -- | Sum of byte sequences of all messages.
  , messageBytes :: {-# UNPACK #-} !ByteStats
  } deriving Show

instance Pretty FlowStats where
  pretty FlowStats {..} =
    PP.int messageCount <+> "messages" $+$
    pretty messageBytes

-- | Zeroed stats.
instance Default FlowStats where
  def = FlowStats 0 def

-- | Monoid under addition.
instance Monoid FlowStats where
  mempty = def
  mappend a b = FlowStats
    { messageBytes = messageBytes a <> messageBytes b
    , messageCount = messageCount a +  messageCount b
    }

-- | Aggregate one more message stats in this direction.
addFlowStats :: ByteStats -> FlowStats -> FlowStats
addFlowStats x FlowStats {..} = FlowStats
  { messageBytes = messageBytes <> x
  , messageCount = succ messageCount
  }

-- | Find average length of byte sequences per message.
avgByteStats :: FlowStats -> ByteStats
avgByteStats (FlowStats n ByteStats {..}) = ByteStats
  { overhead = overhead `quot` n
  , control  = control  `quot` n
  , payload  = payload  `quot` n
  }

-- | Message stats in both directions. This data can be retrieved
-- using 'getStats' function.
--
--   Note that this stats is completely different from
--   'Data.Torrent.Progress.Progress': payload bytes not necessary
--   equal to downloaded\/uploaded bytes since a peer can send a
--   broken block.
--
data ConnectionStats = ConnectionStats
  { -- | Received messages stats.
    incomingFlow  :: !FlowStats
    -- | Sent messages stats.
  , outcomingFlow :: !FlowStats
  } deriving Show

instance Pretty ConnectionStats where
  pretty ConnectionStats {..} = vcat
    [ "Recv:" <+> pretty incomingFlow
    , "Sent:" <+> pretty outcomingFlow
    , "Both:" <+> pretty (incomingFlow <> outcomingFlow)
    ]

-- | Zeroed stats.
instance Default ConnectionStats where
  def = ConnectionStats def def

-- | Monoid under addition.
instance Monoid ConnectionStats where
  mempty = def
  mappend a b = ConnectionStats
    { incomingFlow  = incomingFlow  a <> incomingFlow  b
    , outcomingFlow = outcomingFlow a <> outcomingFlow b
    }

-- | Aggregate one more message stats in the /specified/ direction.
addStats :: ChannelSide -> ByteStats -> ConnectionStats -> ConnectionStats
addStats ThisPeer   x s = s { outcomingFlow = addFlowStats x (outcomingFlow s) }
addStats RemotePeer x s = s { incomingFlow  = addFlowStats x (incomingFlow  s) }

-- | Sum of overhead and control bytes in both directions.
wastedBytes :: ConnectionStats -> Int
wastedBytes ConnectionStats {..} = overhead + control
  where
    FlowStats _ ByteStats {..} = incomingFlow <> outcomingFlow

-- | Sum of payload bytes in both directions.
payloadBytes :: ConnectionStats -> Int
payloadBytes ConnectionStats {..} =
  payload (messageBytes (incomingFlow <> outcomingFlow))

-- | Sum of any bytes in both directions.
transmittedBytes :: ConnectionStats -> Int
transmittedBytes ConnectionStats {..} =
  byteLength (messageBytes (incomingFlow <> outcomingFlow))

{-----------------------------------------------------------------------
--  Flood protection
-----------------------------------------------------------------------}

defaultFloodFactor :: Int
defaultFloodFactor = 1

-- | This is a very permissive value, connection setup usually takes
-- around 10-100KB, including both directions.
defaultFloodThreshold :: Int
defaultFloodThreshold = 2 * 1024 * 1024

-- | A flood detection function.
type Detector stats = Int   -- ^ Factor;
                   -> Int   -- ^ Threshold;
                   -> stats -- ^ Stats to analyse;
                   -> Bool  -- ^ Is this a flooded connection?

defaultDetector :: Detector ConnectionStats
defaultDetector factor threshold s =
  transmittedBytes s     > threshold &&
  factor * wastedBytes s > payloadBytes s

-- | Flood detection is used to protect /this/ peer against a /remote/
-- malicious peer sending meaningless control messages.
data FloodDetector = FloodDetector
  { -- | Max ratio of payload bytes to control bytes.
    floodFactor    :: {-# UNPACK #-} !Int

    -- | Max count of bytes connection /setup/ can take including
    -- 'Handshake', 'ExtendedHandshake', 'Bitfield', 'Have' and 'Port'
    -- messages. This value is used to avoid false positives at the
    -- connection initialization.
  , floodThreshold :: {-# UNPACK #-} !Int

    -- | Flood predicate on the /current/ 'ConnectionStats'.
  , floodPredicate :: Detector ConnectionStats
  } deriving Show

-- | Flood detector with very permissive options.
instance Default FloodDetector where
  def = FloodDetector
    { floodFactor    = defaultFloodFactor
    , floodThreshold = defaultFloodThreshold
    , floodPredicate = defaultDetector
    }

-- | This peer might drop connection if the detector gives positive answer.
runDetector :: FloodDetector -> ConnectionStats -> Bool
runDetector FloodDetector {..} = floodPredicate floodFactor floodThreshold

{-----------------------------------------------------------------------
--  Options
-----------------------------------------------------------------------}

-- | Various connection settings and limits.
data Options = Options
  { -- | How often /this/ peer should send 'KeepAlive' messages.
    keepaliveInterval   :: {-# UNPACK #-} !Int

    -- | /This/ peer will drop connection if a /remote/ peer did not
    -- send any message for this period of time.
  , keepaliveTimeout    :: {-# UNPACK #-} !Int

    -- | Used to protect against flood attacks.
  , floodDetector       :: FloodDetector

    -- | Used to protect against flood attacks in /metadata
    -- exchange/. Normally, a requesting peer should request each
    -- 'InfoDict' piece only one time, but a malicious peer can
    -- saturate wire with 'MetadataRequest' messages thus flooding
    -- responding peer.
    --
    --   This value set upper bound for number of 'MetadataRequests'
    --   for each piece.
    --
  , metadataFactor      :: {-# UNPACK #-} !Int

    -- | Used to protect against out-of-memory attacks: malicious peer
    -- can claim that 'totalSize' is, say, 100TB and send some random
    -- data instead of infodict pieces. Since requesting peer unable
    -- to check not completed infodict via the infohash, the
    -- accumulated pieces will allocate the all available memory.
    --
    --   This limit set upper bound for 'InfoDict' size. See
    --   'ExtendedMetadata' for more info.
    --
  , maxInfoDictSize     :: {-# UNPACK #-} !Int
  } deriving Show

-- | Permissive default parameters, most likely you don't need to
-- change them.
instance Default Options where
  def = Options
    { keepaliveInterval = defaultKeepAliveInterval
    , keepaliveTimeout  = defaultKeepAliveTimeout
    , floodDetector     = def
    , metadataFactor    = defaultMetadataFactor
    , maxInfoDictSize   = defaultMaxInfoDictSize
    }

{-----------------------------------------------------------------------
--  Connection
-----------------------------------------------------------------------}

-- | Connection keep various info about both peers.
data Connection = Connection
  { -- | /Both/ peers handshaked with this protocol string. The only
    -- value is \"Bittorrent Protocol\" but this can be changed in
    -- future.
    connProtocol     :: !ProtocolName

    -- | A set of enabled extensions. This value used to check if a
    -- message is allowed to be sent or received.
  , connCaps         :: !Caps

    -- | /Both/ peers handshaked with this infohash. A connection can
    -- handle only one topic, use 'reconnect' to change the current
    -- topic.
  , connTopic        :: !InfoHash

    -- | Typically extracted from handshake.
  , connRemotePeerId :: !PeerId

    -- | Typically extracted from handshake.
  , connThisPeerId   :: !PeerId

    -- |
  , connOptions      :: !Options

    -- | If @not (allowed ExtExtended connCaps)@ then this set is
    -- always empty. Otherwise it has extension protocol 'MessageId'
    -- map.
  , connExtCaps      :: !(IORef ExtendedCaps)

    -- | Various stats about messages sent and received. Stats can be
    -- used to protect /this/ peer against flood attacks.
  , connStats        :: !(IORef ConnectionStats)
  }

instance Pretty Connection where
  pretty Connection {..} = "Connection"

-- TODO check extended messages too
isAllowed :: Connection -> Message -> Bool
isAllowed Connection {..} msg
  | Just ext <- requires msg = ext `allowed` connCaps
  |          otherwise       = True

{-----------------------------------------------------------------------
--  Hanshaking
-----------------------------------------------------------------------}

sendHandshake :: Socket -> Handshake -> IO ()
sendHandshake sock hs = sendAll sock (S.encode hs)

-- TODO drop connection if protocol string do not match
recvHandshake :: Socket -> IO Handshake
recvHandshake sock = do
    header <- BS.recv sock 1
    unless (BS.length header == 1) $
      throw $ userError "Unable to receive handshake header."

    let protocolLen = BS.head header
    let restLen     = handshakeSize protocolLen - 1

    body <- BS.recv sock restLen
    let resp = BS.cons protocolLen body
    either (throwIO . userError) return $ S.decode resp

-- | Handshaking with a peer specified by the second argument.
--
--   It's important to send handshake first because /accepting/ peer
--   do not know handshake topic and will wait until /connecting/ peer
--   will send handshake.
--
initiateHandshake :: Socket -> Handshake -> IO Handshake
initiateHandshake sock hs = do
  sendHandshake sock hs
  recvHandshake sock

-- | Tries to connect to peer using reasonable default parameters.
connectToPeer :: PeerAddr -> IO Socket
connectToPeer p = do
  sock <- socket AF_INET Stream Network.Socket.defaultProtocol
  connect sock (peerSockAddr p)
  return sock

{-----------------------------------------------------------------------
--  Wire
-----------------------------------------------------------------------}

-- | do not expose this so we can change it without breaking api
type Connected = ReaderT Connection

-- | A duplex channel connected to a remote peer which keep tracks
-- connection parameters.
type Wire a = ConduitM Message Message (Connected IO) a

{-----------------------------------------------------------------------
--  Query
-----------------------------------------------------------------------}

readRef :: (Connection -> IORef a) -> Connected IO a
readRef f = do
  ref <- asks f
  liftIO (readIORef ref)

writeRef :: (Connection -> IORef a) -> a -> Connected IO ()
writeRef f v = do
  ref <- asks f
  liftIO (writeIORef ref v)

modifyRef :: (Connection -> IORef a) -> (a -> a) -> Connected IO ()
modifyRef f m = do
  ref <- asks f
  liftIO (atomicModifyIORef' ref (\x -> (m x, ())))

setExtCaps :: ExtendedCaps -> Wire ()
setExtCaps = lift . writeRef connExtCaps

-- | Get current extended capabilities. Note that this value can
-- change in current session if either this or remote peer will
-- initiate rehandshaking.
getExtCaps :: Wire ExtendedCaps
getExtCaps = lift $ readRef connExtCaps

-- | Get current stats. Note that this value will change with the next
-- sent or received message.
getStats :: Wire ConnectionStats
getStats = lift $ readRef connStats

-- | See the 'Connection' section for more info.
getConnection :: Wire Connection
getConnection = lift ask

{-----------------------------------------------------------------------
--  Wrapper
-----------------------------------------------------------------------}

putStats :: ChannelSide -> Message -> Connected IO ()
putStats side msg = modifyRef connStats (addStats side (stats msg))

validate :: ChannelSide -> Message -> Connected IO ()
validate side msg = do
  caps <- asks connCaps
  case requires msg of
    Nothing  -> return ()
    Just ext
      | ext `allowed` caps -> return ()
      |     otherwise      -> protocolError $ DisallowedMessage side ext

trackFlow :: ChannelSide -> Wire ()
trackFlow side = iterM $ do
  validate side
  putStats side

{-----------------------------------------------------------------------
--  Setup
-----------------------------------------------------------------------}

-- | Normally you should use 'connectWire' or 'acceptWire'.
runWire :: Wire () -> Socket -> Connection -> IO ()
runWire action sock = runReaderT $
  sourceSocket sock        $=
    conduitGet get         $=
      trackFlow RemotePeer $=
         action            $=
      trackFlow ThisPeer   $=
    conduitPut put         $$
  sinkSocket sock

-- | This function will block until a peer send new message. You can
-- also use 'await'.
recvMessage :: Wire Message
recvMessage = await >>= maybe (monadThrow PeerDisconnected) return

-- | You can also use 'yield'.
sendMessage :: PeerMessage msg => msg -> Wire ()
sendMessage msg = do
  ecaps <- getExtCaps
  yield $ envelop ecaps msg

extendedHandshake :: ExtendedCaps -> Wire ()
extendedHandshake caps = do
  -- TODO add other params to the handshake
  sendMessage $ nullExtendedHandshake caps
  msg <- recvMessage
  case msg of
    Extended (EHandshake ExtendedHandshake {..}) -> do
      setExtCaps $ ehsCaps <> caps
    _ -> protocolError HandshakeRefused

rehandshake :: ExtendedCaps -> Wire ()
rehandshake caps = undefined

reconnect :: Wire ()
reconnect = undefined

-- | Initiate 'Wire' connection and handshake with a peer. This
-- function will also do extension protocol handshake if 'ExtExtended'
-- is enabled on both sides.
--
-- This function can throw 'WireFailure' exception.
--
connectWire :: Handshake -> PeerAddr -> ExtendedCaps -> Wire () -> IO ()
connectWire hs addr extCaps wire =
  bracket (connectToPeer addr) close $ \ sock -> do
    hs' <- initiateHandshake sock hs

    unless (def           == hsProtocol hs') $ do
      throwIO $ ProtocolError $ InvalidProtocol (hsProtocol hs')

    unless (hsProtocol hs == hsProtocol hs') $ do
      throwIO $ ProtocolError $ UnexpectedProtocol (hsProtocol hs')

    unless (hsInfoHash hs == hsInfoHash hs') $ do
      throwIO $ ProtocolError $ UnexpectedTopic (hsInfoHash hs')

    unless (hsPeerId hs' == fromMaybe (hsPeerId hs') (peerId addr)) $ do
      throwIO $ ProtocolError $ UnexpectedPeerId (hsPeerId hs')

    let caps = hsReserved hs <> hsReserved hs'
    let wire' = if ExtExtended `allowed` caps
                then extendedHandshake extCaps >> wire
                else wire

    extCapsRef <- newIORef def
    statsRef   <- newIORef ConnectionStats
      { outcomingFlow = FlowStats 1 $ handshakeStats hs
      , incomingFlow  = FlowStats 1 $ handshakeStats hs'
      }

    runWire wire' sock $ Connection
      { connProtocol     = hsProtocol hs
      , connCaps         = caps
      , connTopic        = hsInfoHash hs
      , connRemotePeerId = hsPeerId   hs'
      , connThisPeerId   = hsPeerId   hs
      , connOptions      = def
      , connExtCaps      = extCapsRef
      , connStats        = statsRef
      }

-- | Accept 'Wire' connection using already 'Network.Socket.accept'ed
--   socket. For peer listener loop the 'acceptSafe' should be
--   prefered against 'accept'. The socket will be closed at exit.
--
--   This function can throw 'WireFailure' exception.
--
acceptWire :: Socket -> Wire () -> IO ()
acceptWire sock wire = do
  bracket (return sock) close $ \ _ -> do
    error "acceptWire: not implemented"