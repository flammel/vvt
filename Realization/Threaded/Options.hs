module Realization.Threaded.Options where

data TranslationOptions = TranslationOptions { dedicatedErrorState :: Bool
                                             , safeSteps :: Bool
                                             }
