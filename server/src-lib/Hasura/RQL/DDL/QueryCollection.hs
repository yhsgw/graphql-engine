module Hasura.RQL.DDL.QueryCollection
  ( runCreateCollection
  , runDropCollection
  , runAddQueryToCollection
  , runDropQueryFromCollection
  , runAddCollectionToAllowlist
  , runDropCollectionFromAllowlist
  , fetchAllCollections
  , fetchAllowlist
  , module Hasura.RQL.Types.QueryCollection
  ) where

import           Hasura.Prelude

import qualified Data.HashMap.Strict.InsOrd       as OMap
import qualified Data.HashSet.InsOrd              as HSIns

import           Data.Text.Extended

import           Hasura.Base.Error
import           Hasura.EncJSON
import           Hasura.RQL.Types
import           Hasura.RQL.Types.QueryCollection
import           Hasura.Session

runCreateCollection
  :: (QErrM m, CacheRWM m, MetadataM m)
  => CreateCollection -> m EncJSON
runCreateCollection cc@(CreateCollection collectionName _ _) = do
  collDetM <- getCollectionDefM collectionName
  withPathK "name" $
    onJust collDetM $ const $ throw400 AlreadyExists $
      "query collection with name " <> collectionName <<> " already exists"
  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ metaQueryCollections %~ OMap.insert collectionName cc
  return successMsg

runAddQueryToCollection
  :: (CacheRWM m, MonadError QErr m, MetadataM m)
  => AddQueryToCollection -> m EncJSON
runAddQueryToCollection (AddQueryToCollection collName queryName query) = do
  (CreateCollection _ (CollectionDef qList) comment) <- getCollectionDef collName

  let collDef = CollectionDef $ qList <> pure listQ
  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ metaQueryCollections
      %~ OMap.insert collName (CreateCollection collName collDef comment)
  return successMsg
  where
    listQ = ListedQuery queryName query

runDropCollection
  :: (MonadError QErr m, MetadataM m, CacheRWM m)
  => DropCollection -> m EncJSON
runDropCollection (DropCollection collName cascade) = do
  allowlistModifier <- withPathK "collection" $ do
    void $ getCollectionDef collName
    allowlist <- fetchAllowlist
    if collName `elem` allowlist && not cascade then
        throw400 DependencyError $ "query collection with name "
          <> collName <<> " is present in allowlist; cannot proceed to drop"
      else
        pure $ metaAllowlist %~ HSIns.delete (CollectionReq collName)

  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ allowlistModifier . (metaQueryCollections %~ OMap.delete collName)

  pure successMsg

runDropQueryFromCollection
  :: (CacheRWM m, MonadError QErr m, MetadataM m)
  => DropQueryFromCollection -> m EncJSON
runDropQueryFromCollection (DropQueryFromCollection collName queryName) = do
  CreateCollection _ (CollectionDef qList) _ <- getCollectionDef collName
  let queryExists = flip any qList $ \q -> _lqName q == queryName
  unless queryExists $ throw400 NotFound $ "query with name "
    <> queryName <<> " not found in collection " <>> collName

  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ metaQueryCollections.ix collName.ccDefinition.cdQueries
      %~ filter ((/=) queryName . _lqName)
  pure successMsg

runAddCollectionToAllowlist
  :: (MonadError QErr m, MetadataM m, CacheRWM m)
  => CollectionReq -> m EncJSON
runAddCollectionToAllowlist req@(CollectionReq collName) = do
  void $ withPathK "collection" $ getCollectionDef collName
  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ metaAllowlist %~ HSIns.insert req
  pure successMsg

runDropCollectionFromAllowlist
  :: (UserInfoM m, MonadError QErr m, MetadataM m, CacheRWM m)
  => CollectionReq -> m EncJSON
runDropCollectionFromAllowlist req@(CollectionReq collName) = do
  void $ withPathK "collection" $ getCollectionDef collName
  withNewInconsistentObjsCheck
    $ buildSchemaCache
    $ MetadataModifier
    $ metaAllowlist %~ HSIns.delete req
  return successMsg

getCollectionDef
  :: (QErrM m, MetadataM m)
  => CollectionName -> m CreateCollection
getCollectionDef collName = do
  detM <- getCollectionDefM collName
  onNothing detM $ throw400 NotExists $
    "query collection with name " <> collName <<> " does not exists"

getCollectionDefM
  :: (QErrM m, MetadataM m)
  => CollectionName -> m (Maybe CreateCollection)
getCollectionDefM collName =
  OMap.lookup collName <$> fetchAllCollections

fetchAllCollections :: MetadataM m => m QueryCollections
fetchAllCollections =
  _metaQueryCollections <$> getMetadata

fetchAllowlist :: MetadataM m => m [CollectionName]
fetchAllowlist =
  (map _crCollection . toList . _metaAllowlist) <$> getMetadata
