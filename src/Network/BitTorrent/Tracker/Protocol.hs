-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  non-portable
--
--
--   This module provides straigthforward Tracker protocol
--   implementation. The tracker is an HTTP/HTTPS service used to
--   discovery peers for a particular existing torrent and keep
--   statistics about the swarm.
--
--   For more convenient high level API see
--   "Network.BitTorrent.Tracker" module.
--
--   For more information see:
--   <https://wiki.theory.org/BitTorrentSpecification#Tracker_HTTP.2FHTTPS_Protocol>
--
{-# OPTIONS -fno-warn-orphans           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE TemplateHaskell            #-}
module Network.BitTorrent.Tracker.Protocol
       ( Event(..), AnnounceQuery(..), AnnounceInfo(..)
       , ScrapeQuery, ScrapeInfo(..)
       , askTracker, leaveTracker

         -- * Defaults
       , defaultPorts, defaultNumWant
       )
       where

import Control.Applicative
import Control.Monad

import Data.Aeson.TH
import Data.Char as Char
import Data.Map  as M
import Data.Maybe
import Data.List as L
import Data.Word
import Data.Monoid
import Data.BEncode
import Data.ByteString as B
import Data.Text (Text)
import Data.Text.Encoding
import Data.Serialize hiding (Result)
import Data.URLEncoded as URL
import Data.Torrent

import Network
import Network.Socket
import Network.HTTP
import Network.URI

import Network.BitTorrent.Peer

{-----------------------------------------------------------------------
  Announce messages
-----------------------------------------------------------------------}

-- | Events used to specify which kind of tracker request is performed.
data Event = Started
             -- ^ For the first request: when a peer join the swarm.
           | Stopped
             -- ^ Sent when the peer is shutting down.
           | Completed
             -- ^ To be sent when the peer completes a download.
             deriving (Show, Read, Eq, Ord, Enum, Bounded)

$(deriveJSON (L.map toLower . L.dropWhile isLower) ''Event)

-- | A tracker request is HTTP GET request; used to include metrics
--   from clients that help the tracker keep overall statistics about
--   the torrent. The most important, requests are used by the tracker
--   to keep track lists of active peer for a particular torrent.
--
data AnnounceQuery = AnnounceQuery {
     reqInfoHash   :: !InfoHash
     -- ^ Hash of info part of the torrent usually obtained from
     -- 'Torrent'.

   , reqPeerId     :: !PeerId
     -- ^ ID of the peer doing request.

   , reqPort       :: !PortNumber
     -- ^ Port to listen to for connections from other
     -- peers. Normally, tracker should respond with this port when
     -- some peer request the tracker with the same info hash.

   , reqUploaded   :: !Integer
     -- ^ Number of bytes that the peer has uploaded in the swarm.

   , reqDownloaded :: !Integer
     -- ^ Number of bytes downloaded in the swarm by the peer.

   , reqLeft       :: !Integer
     -- ^ Number of bytes needed in order to complete download.

   , reqIP         :: Maybe HostAddress
     -- ^ The peer IP. Needed only when client communicated with
     -- tracker throught a proxy.

   , reqNumWant    :: Maybe Int
     -- ^ Number of peers that the peers wants to receive from. See
     -- note for 'defaultNumWant'.

   , reqEvent      :: Maybe Event
      -- ^ If not specified, the request is regular periodic request.
   } deriving Show

$(deriveJSON (L.map toLower . L.dropWhile isLower) ''AnnounceQuery)

-- | The tracker response includes a peer list that helps the client
--   participate in the torrent. The most important is 'respPeer' list
--   used to join the swarm.
--
data AnnounceInfo =
     Failure Text -- ^ Failure reason in human readable form.
   | AnnounceInfo {
       respWarning     ::  Maybe Text
       -- ^ Human readable warning.

     , respInterval    :: !Int
       -- ^ Recommended interval to wait between requests.

     , respMinInterval ::  Maybe Int
       -- ^ Minimal amount of time between requests. A peer /should/
       -- make timeout with at least 'respMinInterval' value,
       -- otherwise tracker might not respond. If not specified the
       -- same applies to 'respInterval'.

     , respComplete    ::  Maybe Int
       -- ^ Number of peers completed the torrent. (seeders)

     , respIncomplete  ::  Maybe Int
       -- ^ Number of peers downloading the torrent. (leechers)

     , respPeers       :: ![PeerAddr]
       -- ^ Peers that must be contacted.
     } deriving Show

$(deriveJSON (L.map toLower . L.dropWhile isLower) ''AnnounceInfo)

-- | Ports typically reserved for bittorrent P2P listener.
defaultPorts :: [PortNumber]
defaultPorts =  [6881..6889]

-- | Above 25, new peers are highly unlikely to increase download
--   speed.  Even 30 peers is /plenty/, the official client version 3
--   in fact only actively forms new connections if it has less than
--   30 peers and will refuse connections if it has 55.
--
--   So the default value is set to 50 because usually 30-50% of peers
--   are not responding.
--
defaultNumWant :: Int
defaultNumWant = 50

{-----------------------------------------------------------------------
  Bencode announce encoding
-----------------------------------------------------------------------}

instance BEncodable AnnounceInfo where
  toBEncode (Failure t)        = fromAssocs ["failure reason" --> t]
  toBEncode  AnnounceInfo {..} = fromAssocs
    [ "interval"     -->  respInterval
    , "min interval" -->? respMinInterval
    , "complete"     -->? respComplete
    , "incomplete"   -->? respIncomplete
    , "peers"        -->  respPeers
    ]

  fromBEncode (BDict d)
    | Just t <- M.lookup "failure reason" d = Failure <$> fromBEncode t
    | otherwise = AnnounceInfo
                     <$> d >--? "warning message"
                     <*> d >--  "interval"
                     <*> d >--? "min interval"
                     <*> d >--? "complete"
                     <*> d >--? "incomplete"
                     <*> getPeers (M.lookup "peers" d)
      where
        getPeers :: Maybe BEncode -> Result [PeerAddr]
        getPeers (Just (BList l))     = fromBEncode (BList l)
        getPeers (Just (BString s))   = runGet getCompactPeerList s
        getPeers  _                   = decodingError "Peers"

  fromBEncode _ = decodingError "AnnounceInfo"

instance URLShow PortNumber where
  urlShow = urlShow . fromEnum

instance URLShow Word32 where
  urlShow = show

instance URLShow Event where
  urlShow e = urlShow (Char.toLower x : xs)
    where
      -- INVARIANT: this is always nonempty list
      (x : xs) = show e

instance URLEncode AnnounceQuery where
  urlEncode AnnounceQuery {..} = mconcat
      [ s "peer_id"    %=  reqPeerId
      , s "port"       %=  reqPort
      , s "uploaded"   %=  reqUploaded
      , s "downloaded" %=  reqDownloaded
      , s "left"       %=  reqLeft
      , s "ip"         %=? reqIP
      , s "numwant"    %=? reqNumWant
      , s "event"      %=? reqEvent
      ]
    where s :: String -> String;  s = id; {-# INLINE s #-}

encodeRequest :: URI -> AnnounceQuery -> URI
encodeRequest announce req = URL.urlEncode req
                    `addToURI`      announce
                    `addHashToURI`  reqInfoHash req

{-----------------------------------------------------------------------
  Binary announce encoding
-----------------------------------------------------------------------}

type EventId = Word32

eventId :: Event -> EventId
eventId Completed = 1
eventId Started   = 2
eventId Stopped   = 3

-- TODO add Regular event
putEvent :: Putter (Maybe Event)
putEvent Nothing  = putWord32be 0
putEvent (Just e) = putWord32be (eventId e)

getEvent :: Get (Maybe Event)
getEvent = do
  eid <- getWord32be
  case eid of
    0 -> return Nothing
    1 -> return $ Just Completed
    2 -> return $ Just Started
    3 -> return $ Just Stopped
    _ -> fail "unknown event id"

instance Serialize AnnounceQuery where
  put AnnounceQuery {..} = do
    put           reqInfoHash
    put           reqPeerId

    putWord64be $ fromIntegral reqDownloaded
    putWord64be $ fromIntegral reqLeft
    putWord64be $ fromIntegral reqUploaded

    putEvent      reqEvent
    putWord32be $ fromMaybe 0 reqIP
    putWord32be $ 0 -- TODO what the fuck is "key"?
    putWord32be $ fromIntegral $ fromMaybe (-1) reqNumWant

    put           reqPort

  get = do
    ih   <- get
    pid  <- get

    down <- getWord64be
    left <- getWord64be
    up   <- getWord64be

    ev   <- getEvent
    ip   <- getWord32be
    key  <- getWord32be -- TODO
    want <- getWord32be

    port <- get

    return $ AnnounceQuery {
        reqInfoHash   = ih
      , reqPeerId     = pid
      , reqPort       = port
      , reqUploaded   = fromIntegral up
      , reqDownloaded = fromIntegral down
      , reqLeft       = fromIntegral left
      , reqIP         = if ip == 0 then Nothing else Just ip
      , reqNumWant    = if want == -1 then Nothing else Just (fromIntegral want)
      , reqEvent      = ev
      }

instance Serialize AnnounceInfo where
  put (Failure msg) = put $ encodeUtf8 msg
  put  AnnounceInfo {..} = do
    putWord32be $ fromIntegral respInterval
    putWord32be $ fromIntegral $ fromMaybe 0 respIncomplete
    putWord32be $ fromIntegral $ fromMaybe 0 respComplete
    forM_ respPeers put

  get = do
    interval <- getWord32be
    leechers <- getWord32be
    seeders  <- getWord32be
    peers    <- many get

    return $ AnnounceInfo {
        respWarning     = Nothing
      , respInterval    = fromIntegral interval
      , respMinInterval = Nothing
      , respIncomplete  = Just $ fromIntegral leechers
      , respComplete    = Just $ fromIntegral seeders
      , respPeers       = peers
      }

{-----------------------------------------------------------------------
  Scrape messages
-----------------------------------------------------------------------}

type ScrapeQuery = [InfoHash]

-- | Overall information about particular torrent.
data ScrapeInfo = ScrapeInfo {
    -- | Number of seeders - peers with the entire file.
    siComplete   :: {-# UNPACK #-} !Int

    -- | Total number of times the tracker has registered a completion.
  , siDownloaded :: {-# UNPACK #-} !Int

    -- | Number of leechers.
  , siIncomplete :: {-# UNPACK #-} !Int

    -- | Name of the torrent file, as specified by the "name"
    --   file in the info section of the .torrent file.
  , siName       :: !(Maybe Text)
  } deriving (Show, Eq)

$(deriveJSON (L.map toLower . L.dropWhile isLower) ''ScrapeInfo)

instance BEncodable ScrapeInfo where
  toBEncode ScrapeInfo {..} = fromAssocs
    [ "complete"   -->  siComplete
    , "downloaded" -->  siDownloaded
    , "incomplete" -->  siIncomplete
    , "name"       -->? siName
    ]

  fromBEncode (BDict d) =
    ScrapeInfo <$> d >--  "complete"
               <*> d >--  "downloaded"
               <*> d >--  "incomplete"
               <*> d >--? "name"
  fromBEncode _ = decodingError "ScrapeInfo"

instance Serialize ScrapeInfo where
  put ScrapeInfo {..} = do
    putWord32be $ fromIntegral siComplete
    putWord32be $ fromIntegral siDownloaded
    putWord32be $ fromIntegral siIncomplete

  get = do
    seeders   <- getWord32be
    downTimes <- getWord32be
    leechers  <- getWord32be

    return $ ScrapeInfo {
        siComplete   = fromIntegral seeders
      , siDownloaded = fromIntegral downTimes
      , siIncomplete = fromIntegral leechers
      , siName       = Nothing
      }

{-----------------------------------------------------------------------
  Tracker
-----------------------------------------------------------------------}

mkHTTPRequest :: URI -> Request ByteString
mkHTTPRequest uri = Request uri GET [] ""

-- | Send request and receive response from the tracker specified in
-- announce list. This function throws 'IOException' if it couldn't
-- send request or receive response or decode response.
--
askTracker :: URI -> AnnounceQuery -> IO AnnounceInfo
askTracker announce req = do
    let r = mkHTTPRequest (encodeRequest announce req)

    rawResp  <- simpleHTTP r
    respBody <- getResponseBody rawResp
    checkResult $ decoded respBody
  where

    checkResult (Left err)
      = ioError $ userError $ err ++ " in tracker response"
    checkResult (Right (Failure err))
      = ioError $ userError $ show err ++ " in tracker response"
    checkResult (Right resp)          = return resp

-- | The same as the 'askTracker' but ignore response. Used in
-- conjunction with 'Stopped'.
leaveTracker :: URI -> AnnounceQuery -> IO ()
leaveTracker announce req = do
  let r = mkHTTPRequest (encodeRequest announce req)
  void $ simpleHTTP r >>= getResponseBody
