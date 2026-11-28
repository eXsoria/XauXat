module TM where
import Control.Concurrent.STM (STM, TVar, readTVar, modifyTVar')
import qualified Data.Map.Strict as M
lookup :: Ord k => k -> TVar (M.Map k v) -> STM (Maybe v)
lookup k m = M.lookup k <$> readTVar m
insert :: Ord k => k -> v -> TVar (M.Map k v) -> STM ()
insert k v m = modifyTVar' m (M.insert k v)
