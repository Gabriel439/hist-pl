{-# LANGUAGE RecordWildCards #-}


-- | Disjoint-set forest data structure for integer {0..k} ranges.


module DisjointSet
( 
-- * Mutable
  DisjSetM
, new
, union
, lookupMaybeT

-- * Immutable
, DisjSet
, fromList
, lookup
) where

import           Prelude hiding (lookup)
import           System.IO.Unsafe (unsafePerformIO)
-- import           Data.Int (Int32)
import           Control.Applicative ((<$>))
import           Control.Monad (forM_, guard, void)
import qualified Control.Monad.ST as ST
import           Control.Monad.Primitive
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Class (lift)
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM


--------------------------
-- Mutable
--------------------------


-- A disjoint-set forest structure.
data DisjSetM s = DisjSetM
    { parent   :: !(UM.MVector s Int)
    , rank     :: !(UM.MVector s Int) }


-- | Construct a new disjoint set from a {0 .. k-1} set, where
-- 'k' is the given argument.
new :: PrimMonad m => Int -> m (DisjSetM (PrimState m))
new k = do
    parent <- UM.new k
    forM_  [0..k-1] $ \i ->
        UM.unsafeWrite parent i i
    rank <- UM.replicate k 1
    return $ DisjSetM parent rank


-- | Create an equivalence relation between x and y.
union :: (Functor m, PrimMonad m) => Int -> Int -> DisjSetM (PrimState m) -> m ()
union i j disj@DisjSetM{..} = void $ runMaybeT $ do
    x  <- lookupMaybeT i disj
    y  <- lookupMaybeT j disj
    guard $ x /= y
    rx <- lift $ UM.unsafeRead rank x
    ry <- lift $ UM.unsafeRead rank y
    lift $ case compare rx ry of
        LT  -> UM.unsafeWrite parent y x
        GT  -> UM.unsafeWrite parent x y
        EQ  -> do
            UM.unsafeWrite rank y (ry + 1)
            UM.unsafeWrite parent x y


-- | Retrieve equivalence representant for the given element.
lookupMaybeT :: PrimMonad m => Int -> DisjSetM (PrimState m) -> MaybeT m Int
lookupMaybeT i disj@DisjSetM{..} = do
    let n = UM.length rank
    guard $ i >= 0 || i < n
    lift  $ lookupUnsafe i disj


-- | Retrieve equivalence representant for the given element.
lookupUnsafe :: PrimMonad m => Int -> DisjSetM (PrimState m) -> m Int
lookupUnsafe i disj@DisjSetM{..} = do
    par <- UM.unsafeRead parent i
    if i == par
        then return i
        else do
            anc <- lookupUnsafe par disj
            UM.unsafeWrite parent i anc
            return anc


--------------------------
-- Immutable
--------------------------


-- A disjoint-set forest structure (immutable version)
newtype DisjSet = DisjSet { leader :: U.Vector Int }


-- | Construct a disjoint set for a {0 .. k-1} set, from a list
-- of (x, y) equivalence relation pairs.
fromList
    :: Int          -- ^ Numer of elements
    -> [(Int, Int)] -- ^ Equivalence relation
    -> DisjSet
fromList k xs = ST.runST $ do
    disj <- new k
    -- Add relation pairs
    forM_ xs $ \(i, j) ->
        union i j disj
    -- Compress all paths
    forM_ [0..k-1] $ \i ->
        lookupUnsafe i disj
    -- Parent table of the mutable version
    DisjSet <$> U.freeze (parent disj)


-- | Lookup equivalent class representant for the given element.
lookup :: Int -> DisjSet -> Maybe Int
lookup i DisjSet{..} = if i >= 0 && i < n
    then Just (leader U.! i)
    else Nothing
  where
    n = U.length leader
