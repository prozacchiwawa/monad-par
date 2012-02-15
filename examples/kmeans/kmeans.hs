-- K-Means sample from "Parallel and Concurrent Programming in Haskell"
-- Simon Marlow
-- with minor modifications for benchmarking: erjiang
--
-- With three versions:
--   [ kmeans_seq   ]  a sequential version
--   [ kmeans_strat ]  a parallel version using Control.Parallel.Strategies
--   [ kmeans_par   ]  a parallel version using Control.Monad.Par
--
-- Usage (sequential):
--   $ ./kmeans-par
--
-- Usage (Strategies):
--   $ ./kmeans-par strat 600 +RTS -N4

-- Usage (Par monad):
--   $ ./kmeans-par par 600 +RTS -N4

import System.IO
import KMeansCommon
import Data.Array
-- import Data.Vector.Unboxed
import Text.Printf
import Data.List
import Data.Function
import Debug.Trace
import Control.Parallel.Strategies as Strategies
import Control.Monad.Par as Par
import Control.DeepSeq
import System.Environment
import Data.Time.Clock
import Control.Exception
import System.Random.Mersenne

main = do
  clusters <- getClusters "kmeans-clusters"
  printf "%d clusters read\n" (length clusters)
  rs <- newMTGen (Just 42) >>= randoms :: IO [Double]
  let nclusters = length clusters
  args <- getArgs
  t0 <- getCurrentTime
  let points = case args of
                [_, _, npts] -> genPoints rs (read npts)
                _        -> genPoints rs 21
  evaluate (length points)
  printf "%d points generated\n" (length points)
  final_clusters <- case args of
   ["strat",n, _] -> kmeans_strat (read n) nclusters points clusters
   ["par",n, _] -> kmeans_par (read n) nclusters points clusters
   _other -> kmeans_par 5 nclusters points clusters
  t1 <- getCurrentTime
  print final_clusters
  printf "SELFTIMED %.2f\n" (realToFrac (diffUTCTime t1 t0) :: Double)

genPoints :: [Double] -> Int -> [Vector]
genPoints _ 0        = []
genPoints (x:y:xs) n = (Vector (x*5) (y*5) : genPoints xs (n-1))

-- -----------------------------------------------------------------------------
-- K-Means: repeatedly step until convergence (sequential)

kmeans_seq :: Int -> [Vector] -> [Cluster] -> IO [Cluster]
kmeans_seq nclusters points clusters = do
  let
      loop :: Int -> [Cluster] -> IO [Cluster]
      loop n clusters | n > tooMany = do printf "giving up."; return clusters
      loop n clusters = do
      --hPrintf stderr "iteration %d\n" n
      --hPutStr stderr (unlines (map show clusters))
        let clusters' = step nclusters clusters points
        if clusters' == clusters
           then do
               printf "%d iterations\n" n
               return clusters
           else loop (n+1) clusters'
  --
  loop 0 clusters

tooMany = 50

-- -----------------------------------------------------------------------------
-- K-Means: repeatedly step until convergence (Strategies)

split :: Int -> [a] -> [[a]] 
split numChunks l = splitSize (ceiling $ fromIntegral (length l) / fromIntegral numChunks) l
   where
      splitSize _ [] = []
      splitSize i v = take i v : splitSize i (drop i v)

kmeans_strat :: Int -> Int -> [Vector] -> [Cluster] -> IO [Cluster]
kmeans_strat mappers nclusters points clusters = do
  let chunks = split mappers points
  let
      loop :: Int -> [Cluster] -> IO [Cluster]
      loop n clusters | n > tooMany = do printf "giving up."; return clusters
      loop n clusters = do
        hPrintf stderr "iteration %d\n" n
        hPutStr stderr (unlines (map show clusters))
        let
             new_clusterss = map (step nclusters clusters) chunks
                               `using` parList rdeepseq

             clusters' = reduce nclusters new_clusterss

        if clusters' == clusters
           then return clusters
           else loop (n+1) clusters'
  --
  final <- loop 0 clusters
  return final

-- -----------------------------------------------------------------------------
-- K-Means: repeatedly step until convergence (Par monad)

kmeans_par :: Int -> Int -> [Vector] -> [Cluster] -> IO [Cluster]
kmeans_par mappers nclusters points clusters = do
  let chunks = split mappers points
  let
      loop :: Int -> [Cluster] -> IO [Cluster]
      loop n clusters | n > tooMany = do printf "giving up."; return clusters
      loop n clusters = do
        hPrintf stderr "iteration %d\n" n
        hPutStr stderr (unlines (map show clusters))
        let
             new_clusterss = runPar $ Par.parMap (step nclusters clusters) chunks

             clusters' = reduce nclusters new_clusterss

        if clusters' == clusters
           then return clusters
           else loop (n+1) clusters'
  --
  final <- loop 0 clusters
  return final

-- -----------------------------------------------------------------------------
-- Perform one step of the K-Means algorithm

reduce :: Int -> [[Cluster]] -> [Cluster]
reduce nclusters css =
  concatMap combine $ elems $
     accumArray (flip (:)) [] (0,nclusters) [ (clId c, c) | c <- concat css]
 where
  combine [] = []
  combine (c:cs) = [foldr combineClusters c cs]


step :: Int -> [Cluster] -> [Vector] -> [Cluster]
step nclusters clusters points
   = makeNewClusters (assign nclusters clusters points)

-- assign each vector to the nearest cluster centre
assign :: Int -> [Cluster] -> [Vector] -> Array Int [Vector]
assign nclusters clusters points =
    accumArray (flip (:)) [] (0, nclusters-1)
       [ (clId (nearest p), p) | p <- points ]
  where
    nearest p = fst $ minimumBy (compare `on` snd)
                          [ (c, sqDistance (clCent c) p) | c <- clusters ]

makeNewClusters :: Array Int [Vector] -> [Cluster]
makeNewClusters arr =
  filter ((>0) . clCount) $
     [ makeCluster i ps | (i,ps) <- assocs arr ]
                        -- v. important: filter out any clusters that have
                        -- no points.  This can happen when a cluster is not
                        -- close to any points.  If we leave these in, then
                        -- the NaNs mess up all the future calculations.
