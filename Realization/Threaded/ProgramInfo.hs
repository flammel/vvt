{-# LANGUAGE ViewPatterns,ScopedTypeVariables #-}
module Realization.Threaded.ProgramInfo where

import Realization.Threaded.ThreadFinder
import Realization.Threaded.Slicing (getSlicing)

import LLVM.FFI
import Foreign.Ptr (Ptr,nullPtr)
import Data.Set (Set)
import Data.Map (Map)
import qualified Data.Map as Map

data ThreadInfo = ThreadInfo { blockOrder :: [(Ptr BasicBlock,Int)]
                             , entryPoints :: Map (Ptr BasicBlock,Int) ()
                             , threadFunction :: Ptr Function
                             , threadArg :: Maybe (Ptr Argument,Either (Ptr Type) (Ptr IntegerType))
                             , threadSliceMapping :: Map Integer [(Ptr BasicBlock,Int)]
                             , spawnQuantity :: Quantity
                             }

data AllocInfo = AllocInfo { allocQuantity :: Quantity
                           , allocType :: AllocKind
                           , allocSize :: Maybe (Ptr Value) }

data ProgramInfo = ProgramInfo { mainThread :: ThreadInfo
                               , threads :: Map (Ptr CallInst) ThreadInfo
                               , allocations :: Map (Ptr Instruction) AllocInfo
                               , functionReturns :: Map (Ptr Function) (Ptr Type)
                               }

getProgramInfo :: Ptr Module -> Ptr Function -> IO ProgramInfo
getProgramInfo mod mainFun = do
  (entries,order,slMp) <- getSlicing mainFun
  mainLocs <- getThreadSpawns' mod mainFun
  applyLocs mainLocs
    (ProgramInfo { mainThread = ThreadInfo { blockOrder = order
                                           , entryPoints = entries
                                           , threadFunction = mainFun
                                           , threadArg = Nothing
                                           , threadSliceMapping = slMp
                                           , spawnQuantity = Finite 1 }
                 , threads = Map.empty
                 , allocations = Map.empty
                 , functionReturns = Map.empty })
  where
    applyLocs [] pi = return pi
    applyLocs ((ThreadSpawnLocation { spawningInstruction = inst
                                    , spawnedFunction = fun
                                    , quantity = n }):locs) pi
      = case Map.lookup inst (threads pi) of
         Just ti -> applyLocs locs $ pi { threads = Map.insert inst
                                                    (ti { spawnQuantity = (spawnQuantity ti)+n })
                                                    (threads pi) }
         Nothing -> do
           (entries,order,slMp) <- getSlicing fun
           nlocs <- getThreadSpawns' mod fun
           arg <- getThreadArgument fun
           applyLocs (locs++(fmap (updateQuantity (*n)) nlocs))
             (pi { threads = Map.insert inst (ThreadInfo { blockOrder = order
                                                         , entryPoints = entries
                                                         , threadFunction = fun
                                                         , threadArg = arg
                                                         , threadSliceMapping = slMp
                                                         , spawnQuantity = n })
                             (threads pi) })
    applyLocs ((AllocationLocation { allocInstruction = inst
                                   , quantity = n
                                   , allocType' = tp
                                   , allocSize' = sz }):locs) pi
      = applyLocs locs (pi { allocations = Map.insert inst (AllocInfo n tp sz)
                                           (allocations pi) })
    applyLocs ((ReturnLocation { returningFunction = fun
                               , returnedType = tp
                               }):locs) pi
      = applyLocs locs (pi { functionReturns = Map.insertWith
                                               (\tp1 tp2 -> if tp1==tp2
                                                            then tp1
                                                            else error $ "vvt-enc: Conflicting return types in thread.")
                                               fun tp
                                               (functionReturns pi)
                           })