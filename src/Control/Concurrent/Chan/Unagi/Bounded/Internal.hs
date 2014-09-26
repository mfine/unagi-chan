{-# LANGUAGE BangPatterns , DeriveDataTypeable, CPP #-}
module Control.Concurrent.Chan.Unagi.Bounded.Internal
    ( InChan(..), OutChan(..), ChanEnd(..), StreamSegment, Cell(..), Stream(..)
    , writerCheckin, unblockWriters, WriterCheckpoint(..)
    , NextSegment(..), StreamHead(..)
    , newChanStarting, writeChan, readChan, readChanOnException
    -- TODO immediate failing write
    , dupChan
    )
    where

-- NOTE: forked from src/Control/Concurrent/Chan/Unagi/Internal.hs 43706b2
--       some commentary not specific to this Bounded variant has been removed.
--       See the Unagi source for that.

import Control.Concurrent.MVar
import Data.IORef
import Control.Exception
import Control.Monad.Primitive(RealWorld)
import Data.Atomics.Counter.Fat
import Data.Atomics
import qualified Data.Primitive as P
import Control.Monad
import Control.Applicative
import Data.Bits
import Data.Maybe(fromMaybe)
import Data.Typeable(Typeable)
import GHC.Exts(inline)

import Utilities(nextHighestPowerOfTwo)


-- | The write end of a channel created with 'newChan'.
data InChan a = InChan !(Ticket (Cell a)) !(ChanEnd a)
    deriving Typeable

-- | The read end of a channel created with 'newChan'.
newtype OutChan a = OutChan (ChanEnd a)
    deriving Typeable

instance Eq (InChan a) where
    (InChan _ (ChanEnd _ _ _ _ headA)) == (InChan _ (ChanEnd _ _ _ _ headB))
        = headA == headB
instance Eq (OutChan a) where
    (OutChan (ChanEnd _ _ _ _ headA)) == (OutChan (ChanEnd _ _ _ _ headB))
        = headA == headB

data ChanEnd a = 
            -- For efficient div and mod:
    ChanEnd !Int  -- logBase 2 BOUNDS
            !Int  -- BOUNDS - 1
            -- an efficient producer of segments of length BOUNDS:
            !(SegSource a)
            -- Both Chan ends must start with the same counter value.
            !AtomicCounter 
            -- the stream head; this must never point to a segment whose offset
            -- is greater than the counter value
            !(IORef (StreamHead a)) -- NOTE [1]
    deriving Typeable
 -- [1] For the writers' ChanEnd: the segment that appears in the StreamHead is
 -- implicitly unlocked for writers (the segment size being equal to the chan
 -- bounds). See 'writeChan' for notes on how we make sure to keep this
 -- invariant.

data StreamHead a = StreamHead !Int !(Stream a)

-- This is always of length BOUNDS
type StreamSegment a = P.MutableArray RealWorld (Cell a)

data Cell a = Empty | Written a | Blocking !(MVar a)

data Stream a = 
    Stream !(StreamSegment a)
           -- The next segment in the stream; new segments are allocated and
           -- put here by the reader of index-0 of the previous segment. That
           -- reader (and the next one or two) also do a tryPutMVar to the MVar
           -- below, to indicate that any blocked writers may proceed.
           !(IORef (Maybe (NextSegment a)))
           -- writers that find Nothing above, must check in with a possibly
           -- blocking readMVar here before proceeding (the slow path):


-- Next segment, installed by either a reader or a writer:
data NextSegment a = NextByWriter (Stream a)       -- the next stream segment
                                  !WriterCheckpoint -- blocking for this segment
                   -- a reader-installed one is implicitly unlocked for writers
                   -- so needs no checkpoint:
                   | NextByReader (Stream a)

-- helper accessors TODO consider making records
getNextRef :: NextSegment a -> IORef (Maybe (NextSegment a))
getNextRef x = (\(Stream _ nextSegRef)-> nextSegRef) $ getStr x

getStr :: NextSegment a -> Stream a
getStr (NextByReader str) = str
getStr (NextByWriter str _) = str

asReader, asWriter :: Bool
asReader = True
asWriter = False


-- WRITER BLOCKING SCHEME OVERVIEW
-- -------------------------------
-- We use segments of size equal to the requested bounds. When a reader reads
-- index 0 of a segment it tries to pre-allocate the next segment, marking it
-- installed by reader (NextByReader), which indicates to writers who read it
-- that they may write and return without blocking (and this makes the queue
-- loosely bounded between size n and n*2).
--
-- Whenever a reader encounters a segment (in waitingAdvanceStream) installed
-- by a writer it unblocks writers and rewrites the NextBy* constructor to
-- NextByReader, replacing the installed stream segment.
--
-- Writers first make their write available (by writing to the segment) before
-- doing any blocking. This is more efficient, lets us handle async exceptions
-- in a principled way without changing the semantics. This also means that in
-- some cases a writer will install the next segment, marked installed by
-- writer, insicating that writers must checkin and block; readers will mark
-- these segments as installed by reader to avoid unnecessary overhead when the
-- segment becomes unlocked as described in the paragraph above.
--
-- The writer StreamHead is only ever updated by a writer that sees that a
-- segment is unlocked for writing (either because the writer has returned from
-- blocking on that segment, or because it sees that it was installed by a
-- reader); in this way a writer knows if its segment is at the StreamHead that
-- it is free to write and return without blocking (writerCheckin).


newChanStarting :: Int -> Int -> IO (InChan a, OutChan a)
{-# INLINE newChanStarting #-}
newChanStarting !startingCellOffset !sizeDirty = do
    let !size = nextHighestPowerOfTwo sizeDirty
        !logBounds = round $ logBase (2::Float) $ fromIntegral size
        !boundsMn1 = size - 1

    segSource <- newSegmentSource size
    firstSeg <- segSource
    -- collect a ticket to save for writer CAS
    savedEmptyTkt <- readArrayElem firstSeg 0
    stream <- Stream firstSeg <$> newIORef Nothing
    let end = ChanEnd logBounds boundsMn1 segSource 
                  <$> newCounter (startingCellOffset - 1)
                  <*> newIORef (StreamHead startingCellOffset stream)
    assert (size > 0 && (boundsMn1 + 1) == 2 ^ logBounds) $
        liftA2 (,) (InChan savedEmptyTkt <$> end) 
                   (OutChan <$> end)

-- | Duplicate a chan: the returned @OutChan@ begins empty, but data written to
-- the argument @InChan@ from then on will be available from both the original
-- @OutChan@ and the one returned here, creating a kind of broadcast channel.
--
-- Writers will be blocked only when the fastest reader falls behind the
-- bounds; slower readers of duplicated 'OutChan' may fall arbitrarily behind.
dupChan :: InChan a -> IO (OutChan a)
{-# INLINE dupChan #-}
dupChan (InChan _ (ChanEnd logBounds boundsMn1 segSource counter streamHead)) = do
    hLoc <- readIORef streamHead
    loadLoadBarrier  -- NOTE [1]
    wCount <- readCounter counter
    
    counter' <- newCounter wCount 
    streamHead' <- newIORef hLoc
    return $ OutChan $ ChanEnd logBounds boundsMn1 segSource counter' streamHead'
  -- [1] We must read the streamHead before inspecting the counter; otherwise,
  -- as writers write, the stream head pointer may advance past the cell
  -- indicated by wCount.


-- | Write a value to the channel. If the chan is full this will block.
--
-- To be precise this /may/ block when the number of elements in the queue 
-- @>= size@, and will certainly block when @>= size*2@, where @size@ is the
-- argument passed to 'newChan', rounded up to the next highest power of two.
--
-- /Note re. exceptions/: In the case that an async exception is raised 
-- while blocking here, the write will succeed. When not blocking, exceptions
-- are masked. Thus writes always succeed once 'writeChan' is entered.
writeChan :: InChan a -> a -> IO ()
{-# INLINE writeChan #-}
writeChan (InChan savedEmptyTkt ce) = \a-> mask_ $ do 
    (segIx, nextSeg, updateStreamHeadIfNecessary) <- moveToNextCell asWriter ce
    let (seg, writerCheckinCont) = case nextSeg of
          NextByWriter (Stream s _) checkpt -> (s, writerCheckin checkpt)
          -- if installed by reader, no need to check in:
          NextByReader (Stream s _)         -> (s, return ())

    (success,nonEmptyTkt) <- casArrayElem seg segIx savedEmptyTkt (Written a)
    if success
      -- NOTE: We must only block AFTER writing to be async exception-safe.
      then writerCheckinCont
      -- If CAS failed then a reader beat us, so we know we're not out of
      -- bounds and don't need to writerCheckin
      else case peekTicket nonEmptyTkt of
                Blocking v -> putMVar v a
                Empty      -> error "Stored Empty Ticket went stale!"
                Written _  -> error "Nearly Impossible! Expected Blocking"
    
    updateStreamHeadIfNecessary  -- NOTE [1] 
 -- [1] At this point we know that 'seg' is unlocked for writers because a
 -- reader unblocked us, so it's safe to update the StreamHead with this
 -- segment (if we moved to a new segment). This way we maintain the invariant
 -- that the StreamHead segment is always known "unlocked" to writers.


readChanOnExceptionUnmasked :: (IO a -> IO a) -> OutChan a -> IO a
{-# INLINE readChanOnExceptionUnmasked #-}
readChanOnExceptionUnmasked h = \(OutChan ce@(ChanEnd _ _ segSource _ _))-> do
    (segIx, nextSeg, updateStreamHeadIfNecessary) <- moveToNextCell asReader ce
    let (seg,next) = case nextSeg of
            NextByReader (Stream s n) -> (s,n)
            _ -> error "moveToNextCell returned a non-reader-installed next segment to readChanOnExceptionUnmasked"
    -- try to pre-allocate next segment:
    when (segIx == 0) $ void $
      waitingAdvanceStream asReader next segSource 0

    updateStreamHeadIfNecessary

    cellTkt <- readArrayElem seg segIx
    case peekTicket cellTkt of
         Written a -> return a
         Empty -> do
            v <- newEmptyMVar
            (success,elseWrittenCell) <- casArrayElem seg segIx cellTkt (Blocking v)
            if success 
              then readBlocking v
              else case peekTicket elseWrittenCell of
                        -- In the meantime a writer has written. Good!
                        Written a -> return a
                        -- ...or a dupChan reader initiated blocking:
                        Blocking v2 -> readBlocking v2
                        _ -> error "Impossible! Expecting Written or Blocking"
         Blocking v -> readBlocking v
  -- N.B. must use `readMVar` here to support `dupChan`:
  where readBlocking v = inline h $ readMVar v 


-- | Read an element from the chan, blocking if the chan is empty.
--
-- /Note re. exceptions/: When an async exception is raised during a @readChan@ 
-- the message that the read would have returned is likely to be lost, even when
-- the read is known to be blocked on an empty queue. If you need to handle
-- this scenario, you can use 'readChanOnException'.
readChan :: OutChan a -> IO a
{-# INLINE readChan #-}
readChan = readChanOnExceptionUnmasked id

-- | Like 'readChan' but allows recovery of the queue element which would have
-- been read, in the case that an async exception is raised during the read. To
-- be precise exceptions are raised, and the handler run, only when
-- @readChanOnException@ is blocking.
--
-- The second argument is a handler that takes a blocking IO action returning
-- the element, and performs some recovery action.  When the handler is called,
-- the passed @IO a@ is the only way to access the element.
readChanOnException :: OutChan a -> (IO a -> IO ()) -> IO a
{-# INLINE readChanOnException #-}
readChanOnException c h = mask_ $ 
    readChanOnExceptionUnmasked (\io-> io `onException` (h io)) c


-- increments counter, finds stream segment of corresponding cell (updating the
-- stream head pointer as needed), and returns the stream segment and relative
-- index of our cell.
moveToNextCell :: Bool -> ChanEnd a -> IO (Int, NextSegment a, IO ())
{-# INLINE moveToNextCell #-}
moveToNextCell isReader (ChanEnd logBounds boundsMn1 segSource counter streamHead) = do
    (StreamHead offset0 str0) <- readIORef streamHead
#ifdef NOT_x86 
    -- fetch-and-add is a full barrier on x86
    loadLoadBarrier
#endif
    ix <- incrCounter 1 counter
    let !relIx = ix - offset0
        !segsAway = relIx `unsafeShiftR` logBounds -- `div` bounds
        !segIx    = relIx .&. boundsMn1            -- `mod` bounds
        ~nEW_SEGMENT_WAIT = (boundsMn1 `div` 12) + 25 
    
        {-# INLINE go #-}
        go  0 nextSeg = return nextSeg
        go !n nextSeg =
            waitingAdvanceStream isReader (getNextRef nextSeg) segSource (nEW_SEGMENT_WAIT*segIx) -- NOTE [1]
              >>= go (n-1)
 
    nextSeg <- assert (relIx >= 0) $
                 go segsAway $ NextByReader str0  -- NOTE [2]

    -- writers and readers must perform this continuation at different points:
    let updateStreamHeadIfNecessary = 
          when (segsAway > 0) $ do
            let !offsetN = --(segsAway * bounds)
                   offset0 + (segsAway `unsafeShiftL` logBounds) 
            writeIORef streamHead $ StreamHead offsetN $ getStr nextSeg

    return (segIx, nextSeg, updateStreamHeadIfNecessary)
  -- [1] All readers or writers needing to work with a not-yet-created segment
  -- race to create it, but those past index 0 have progressively long waits.
  -- The constant here is an approximation of the way we calculate it in
  -- Control.Concurrent.Chan.Unagi.Constants.nEW_SEGMENT_WAIT
  --
  -- [2] We start the loop with 'NextByReader' effectively meaning that the head
  -- segment was installed by a reader, or really just indicating that the
  -- writer has no need to check-in for blocking. This is always the case for
  -- the head stream; see `writeChan` NOTE 1.



-- TODO play with inlining and look at core; we'd like the conditionals to disappear
-- INVARIANTS: 
--   - if isReader, after returning, the nextSegRef will be marked NextByReader
--   - the 'nextSegRef' is only ever modified from Nothing -> Just (NextBy*)
waitingAdvanceStream :: Bool -> IORef (Maybe (NextSegment a)) -> SegSource a 
                     -> Int -> IO (NextSegment a)
waitingAdvanceStream isReader nextSegRef segSource = go where
  cas tk = casIORef nextSegRef tk . Just

  -- extract the installed Just NextSegment from the result of the cas
  peekInstalled (_, nextSegTk) =
     fromMaybe (error "Impossible! This should only have been a Just NextBy* segment") $
       peekTicket nextSegTk

  readerUnblockAndReturn nextSeg = assert isReader $ case nextSeg of
      -- if a writer won, try to set as NextByReader so that every writer
      -- to this seg doesn't have to check in, and unblockWriters
      NextByWriter strAlreadyInstalled checkpt -> do
          unblockWriters checkpt  -- idempotent
          let nextSeg' = NextByReader strAlreadyInstalled
          writeIORef nextSegRef $ Just nextSeg'
          return nextSeg'

      nextByReader -> return nextByReader

  go wait = assert (wait >= 0) $ do
    tk <- readForCAS nextSegRef
    case peekTicket tk of
         -- Rare, slow path: In readers, we outran reader 0 of the previous
         -- segment (or it was descheduled) who was tasked with setting this up
         -- In writers, there are number writer threads > bounds, or reader 0
         -- of previous segment was slow or descheduled.
         Nothing 
           | wait > 0 -> go (wait - 1)
             -- Create a potential next segment and try to insert it:
           | otherwise -> do 
               potentialStrNext <- Stream <$> segSource <*> newIORef Nothing
               if isReader
                 then do
                   -- This may fail because of either a competing reader or
                   -- writer which certainly modified this to a Just value
                   installed <- cas tk $ NextByReader potentialStrNext
#ifdef NOT_x86 
                   -- ensure strNext is in place before unblocking writers,
                   -- where CAS is not a full barrier:
                   writeBarrier
#endif
                   readerUnblockAndReturn $ peekInstalled installed
                 else do
                   potentialCheckpt <- WriterCheckpoint <$> newEmptyMVar
                   -- This may fail because of either a competing reader or
                   -- writer which certainly modified this to a Just value
                   peekInstalled <$> (cas tk $ 
                           NextByWriter potentialStrNext potentialCheckpt)
   
         -- Fast path: Another reader or writer has already advanced the
         -- stream. Most likely reader 0 of the last segment.
         Just nextSeg 
           | isReader  -> readerUnblockAndReturn nextSeg
           | otherwise -> return nextSeg

type SegSource a = IO (StreamSegment a)

newSegmentSource :: Int -> IO (SegSource a)
newSegmentSource size = do
    arr <- P.newArray size Empty
    return (P.cloneMutableArray arr 0 size)


-- This begins empty, but several readers will `put` without coordination, to
-- ensure it's filled. Meanwhile writers are blocked on a `readMVar` (see
-- writerCheckin) waiting to proceed. 
newtype WriterCheckpoint = WriterCheckpoint (MVar ())

-- idempotent
unblockWriters :: WriterCheckpoint -> IO ()
unblockWriters (WriterCheckpoint v) =
    void $ tryPutMVar v ()

-- A writer knows that it doesn't need to call this when:
--   - its segment is in the StreamHead, or...
--   - its segment was reached by a NextByReader
writerCheckin :: WriterCheckpoint -> IO ()
writerCheckin (WriterCheckpoint v) = do
-- On GHC > 7.8 we have an atomic `readMVar`.  On earlier GHC readMVar is
-- take+put, creating a race condition; in this case we use take+tryPut
-- ensuring the MVar stays full even if a reader's tryPut slips an () in:
#if __GLASGOW_HASKELL__ < 708
    takeMVar v >>= void . tryPutMVar v
#else
    void $ readMVar v
#endif
    -- make sure we can see the reader's segment creation once we unblock...
    loadLoadBarrier
    -- ... and proceed to readIORef the segment
