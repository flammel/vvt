{-# LANGUAGE ScopedTypeVariables,TypeFamilies,ViewPatterns #-}
module Realization.Threaded.ThreadFinder where

import LLVM.FFI
import LLVM.FFI.Loop
import Foreign.Ptr (Ptr,nullPtr)
import Foreign.Storable (peek)

data Quantity = Finite Integer
              | Infinite
              deriving (Show,Eq)

data ThreadLocation = ThreadSpawnLocation { spawningInstruction :: Ptr CallInst
                                          , spawnedFunction :: Ptr Function
                                          , quantity :: Quantity
                                          }
                    | AllocationLocation { allocInstruction :: Ptr Instruction
                                         , quantity :: Quantity
                                         , allocType' :: Ptr Type
                                         , allocSize' :: Maybe (Ptr Value)
                                         }
                    deriving (Show,Eq,Ord)

getThreadSpawns' :: Ptr Module -> Ptr Function -> IO [ThreadLocation]
getThreadSpawns' mod fun = do
  loopInfo <- newLoopInfo
  manager <- newFunctionPassManager mod
  functionPassManagerAdd manager loopInfo
  errors <- functionPassManagerRun manager fun
  if not errors
    then do
    base <- loopInfoGetBase loopInfo
    getThreadSpawns fun base
    else error "Failed to run loop info pass."

getThreadSpawns :: Ptr Function -> Ptr (LoopInfoBase BasicBlock Loop) -> IO [ThreadLocation]
getThreadSpawns fun loopInfo = do
  blks <- getBasicBlockList fun >>= ipListToList
  analyzeBlocks blks
  where
    analyzeBlocks [] = return []
    analyzeBlocks (blk:blks) = do
      instrs <- getInstList blk >>= ipListToList
      analyzeInstructions instrs blk blks
    analyzeInstructions [] _ blks = analyzeBlocks blks
    analyzeInstructions (i:is) blk blks = case castDown i of
      Just call -> do
        cv <- callInstGetCalledValue call
        case castDown cv of
         Just (fun::Ptr Function) -> do
           name <- getNameString fun
           case name of
            "pthread_create" -> do
              threadVal <- callInstGetArgOperand call 2
              case castDown threadVal of
               Just threadFun -> do
                 loop <- loopInfoBaseGetLoopFor loopInfo blk
                 rest <- analyzeInstructions is blk blks
                 return $ (ThreadSpawnLocation { spawningInstruction = call
                                               , spawnedFunction = threadFun
                                               , quantity = if loop==nullPtr
                                                            then Finite 1
                                                            else Infinite
                                               }):rest
               Nothing -> error "Spawning dynamic functions not supported."
            "malloc" -> do
              sz <- callInstGetArgOperand call 0
              tp <- usedType i
              rtp <- case tp of
                Just r -> return r
                Nothing -> do
                  ctp <- getType i
                  case castDown ctp of
                    Just (ptp::Ptr PointerType) -> sequentialTypeGetElementType ptp
              rsz <- case castDown sz of
                Just isz -> do
                  APInt _ val <- constantIntGetValue isz >>= peek
                  byteSize <- simpleTypeByteSize rtp
                  return (Just (val `div` byteSize))
                Nothing -> return Nothing
              loop <- loopInfoBaseGetLoopFor loopInfo blk
              rest <- analyzeInstructions is blk blks
              let quant = case (loop==nullPtr,rsz) of
                            (True,Just n) -> Finite n
                            (False,Just 1) -> Infinite
                            (True,Nothing) -> Infinite
              return $ AllocationLocation { allocInstruction = i
                                          , quantity = quant
                                          , allocType' = rtp
                                          , allocSize' = case quant of
                                                           Infinite -> Just sz
                                                           _ -> Nothing }:rest
            "calloc" -> do
              -- XXX: Ignore the member size parameter for now...
              num <- callInstGetArgOperand call 0
              tp <- usedType i
              case tp of
               Nothing -> error $ "Callocs that aren't casted aren't supported yet."
               Just rtp -> do
                 loop <- loopInfoBaseGetLoopFor loopInfo blk
                 rest <- analyzeInstructions is blk blks
                 return $ AllocationLocation { allocInstruction = i
                                             , quantity = if loop==nullPtr
                                                          then Finite 1
                                                          else Infinite
                                             , allocType' = rtp
                                             , allocSize' = Just num }:rest
            _ -> analyzeInstructions is blk blks
      Nothing -> case castDown i of
        Just alloc -> do
          loop <- loopInfoBaseGetLoopFor loopInfo blk
          rest <- analyzeInstructions is blk blks
          tp <- getType (alloc :: Ptr AllocaInst) >>= sequentialTypeGetElementType
          sz <- allocaInstGetArraySize alloc
          return $ (AllocationLocation { allocInstruction = i
                                       , quantity = if loop==nullPtr
                                                    then Finite 1
                                                    else Infinite
                                       , allocType' = tp
                                       , allocSize' = if loop==nullPtr
                                                      then Nothing
                                                      else Just sz
                                       }):rest
        Nothing -> analyzeInstructions is blk blks

getThreadArgument :: Ptr Function -> IO (Maybe (Ptr Argument,Ptr Type))
getThreadArgument fun = do
  args <- functionGetArgumentList fun >>= ipListToList
  case args of
   [] -> return Nothing
   arg:_ -> do
     tp <- usedType arg
     case tp of
      Nothing -> return Nothing
      Just tp -> return (Just (arg,tp))

usedType :: ValueC v => Ptr v -> IO (Maybe (Ptr Type))
usedType val = do
  begin <- valueUseBegin val
  end <- valueUseEnd val
  getUses begin end
  where
    getUses cur end = do
      isEnd <- valueUseIteratorEq cur end
      if isEnd
        then return Nothing
        else do
        user <- valueUseIteratorDeref cur >>= useGetUser
        case castDown user of
         Just bitcast -> do
           tp <- getType (bitcast :: Ptr BitCastInst)
           case castDown tp of
            Just ptp -> do
              rtp <- sequentialTypeGetElementType (ptp :: Ptr PointerType)
              nxt <- valueUseIteratorNext cur
              getUses' rtp nxt end
            Nothing -> error "Bitcast is not a pointer."
         Nothing -> do
           nxt <- valueUseIteratorNext cur
           getUses nxt end
    getUses' tp cur end = do
      isEnd <- valueUseIteratorEq cur end
      if isEnd
        then return (Just tp)
        else do
        user <- valueUseIteratorDeref cur >>= useGetUser
        case castDown user of
         Just bitcast -> do
           tp <- getType (bitcast :: Ptr BitCastInst)
           case castDown tp of
            Just ptp -> do
              rtp <- sequentialTypeGetElementType (ptp :: Ptr PointerType)
              nxt <- valueUseIteratorNext cur
              if rtp==tp
                then getUses' tp nxt end
                else error "Pointer is bitcast to multiple different types."
            Nothing -> error "Bitcast is not a pointer."
         Nothing -> do
           nxt <- valueUseIteratorNext cur
           getUses' tp nxt end

simpleTypeByteSize :: Ptr Type -> IO Integer
simpleTypeByteSize (castDown -> Just itp) = do
  sz <- getBitWidth itp
  return (sz `div` 8)

instance Num Quantity where
  (+) Infinite _ = Infinite
  (+) _ Infinite = Infinite
  (+) (Finite n) (Finite m) = Finite (n*m)
  (-) Infinite _ = Infinite
  (-) _ Infinite = Infinite
  (-) (Finite n) (Finite m) = Finite (n-m)
  (*) (Finite n) (Finite m) = Finite (n*m)
  (*) _ _ = Infinite
  abs Infinite = Infinite
  abs (Finite n) = Finite (abs n)
  signum Infinite = Infinite
  signum (Finite n) = Finite (signum n)
  fromInteger n = Finite n

instance Ord Quantity where
  compare Infinite Infinite = EQ
  compare Infinite _ = GT
  compare _ Infinite = LT
  compare (Finite n) (Finite m) = compare n m
