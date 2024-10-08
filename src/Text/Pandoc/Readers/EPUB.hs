{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{- |
   Module      : Text.Pandoc.Readers.EPUB
   Copyright   : Copyright (C) 2014-2020 Matthew Pickering
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of EPUB to 'Pandoc' document.
-}

module Text.Pandoc.Readers.EPUB
  (readEPUB)
  where

import Codec.Archive.Zip (Archive (..), Entry(..), findEntryByPath, fromEntry,
                          toArchiveOrFail)
import Control.DeepSeq (NFData, deepseq)
import Control.Monad (guard, liftM, liftM2, mplus)
import Control.Monad.Except (throwError)
import qualified Data.ByteString.Lazy as BL (ByteString)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Map as M (Map, elems, fromList, lookup)
import Data.Maybe (mapMaybe)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import Network.URI (unEscapeString, parseRelativeReference, URI(..))
import System.FilePath (dropFileName, dropFileName, normalise, splitFileName,
                        takeFileName, (</>))
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Class.PandocMonad (PandocMonad, insertMedia)
import Text.Pandoc.Definition hiding (Attr)
import Text.Pandoc.Error
import Text.Pandoc.Extensions (Extension (Ext_raw_html), enableExtension)
import Text.Pandoc.MIME (MimeType)
import Text.Pandoc.Options (ReaderOptions (..))
import Text.Pandoc.Readers.HTML (readHtml)
import Text.Pandoc.Shared (addMetaField, collapseFilePath, tshow)
import Text.Pandoc.URI (escapeURI)
import qualified Text.Pandoc.UTF8 as UTF8 (toTextLazy)
import Text.Pandoc.Walk (query, walk)
import Text.Pandoc.XML.Light

type Items = M.Map Text (FilePath, MimeType)

readEPUB :: PandocMonad m => ReaderOptions -> BL.ByteString -> m Pandoc
readEPUB opts bytes = case toArchiveOrFail bytes of
  Right archive -> archiveToEPUB opts archive
  Left  e       -> throwError $ PandocParseError $
                     "Couldn't extract ePub file: " <> T.pack e

-- runEPUB :: Except PandocError a -> Either PandocError a
-- runEPUB = runExcept

-- Note that internal reference are aggressively normalised so that all ids
-- are of the form "filename#id"
--
archiveToEPUB :: (PandocMonad m) => ReaderOptions -> Archive -> m Pandoc
archiveToEPUB os archive = do
  -- root is path to folder with manifest file in
  (root, content) <- getManifest archive
  (coverId, meta) <- parseMeta content
  (cover, items)  <- parseManifest content coverId
  -- No need to collapse here as the image path is from the manifest file
  let coverDoc = maybe mempty imageToPandoc cover
  spine <- parseSpine items content
  let escapedSpine = map (escapeURI . T.pack . takeFileName . fst) spine
  Pandoc _ bs <-
      foldM' (\a b -> ((a <>) . walk (prependHash escapedSpine))
        `liftM` parseSpineElem root b) mempty spine
  let ast = coverDoc <> Pandoc meta bs
  fetchImages (M.elems items) root archive ast
  return ast
  where
    os' = os {readerExtensions = enableExtension Ext_raw_html (readerExtensions os)}
    parseSpineElem :: PandocMonad m => FilePath -> (FilePath, MimeType) -> m Pandoc
    parseSpineElem (normalise -> r) (normalise -> path, mime) = do
      doc <- mimeToReader mime r path
      let docSpan = B.doc $ B.para $ B.spanWith (T.pack $ takeFileName path, [], []) mempty
      return $ docSpan <> doc
    mimeToReader :: PandocMonad m => MimeType -> FilePath -> FilePath -> m Pandoc
    mimeToReader "application/xhtml+xml" (unEscapeString -> root)
                                         (unEscapeString -> path) = do
      fname <- findEntryByPathE (root </> path) archive
      html <- readHtml os' . TL.toStrict . TL.decodeUtf8 $ fromEntry fname
      return $ fixInternalReferences path html
    mimeToReader s _ (unEscapeString -> path)
      | s `elem` imageMimes = return $ imageToPandoc path
      | otherwise = return mempty

-- paths should be absolute when this function is called
-- renameImages should do this
fetchImages :: PandocMonad m
            => [(FilePath, MimeType)]
            -> FilePath -- ^ Root
            -> Archive
            -> Pandoc
            -> m ()
fetchImages mimes root arc (query iq -> links) =
    mapM_ (uncurry3 insertMedia) (mapMaybe getEntry links)
  where
    getEntry link =
        let abslink = normalise (unEscapeString (root </> link)) in
        (link , lookup link mimes, ) . fromEntry
          <$> findEntryByPath abslink arc

iq :: Inline -> [FilePath]
iq (Image _ _ (url, _)) = [T.unpack url]
iq _                    = []

-- Remove relative paths
renameImages :: FilePath -> Inline -> Inline
renameImages root img@(Image attr a (url, b))
  | "data:" `T.isPrefixOf` url = img
  | otherwise                  = Image attr a ( T.pack $ collapseFilePath (root </> T.unpack url)
                                              , b)
renameImages _ x = x

imageToPandoc :: FilePath -> Pandoc
imageToPandoc s = B.doc . B.para $ B.image (T.pack s) "" mempty

imageMimes :: [MimeType]
imageMimes = ["image/gif", "image/jpeg", "image/png"]

type CoverId = Text

type CoverImage = FilePath

parseManifest :: (PandocMonad m)
              => Element -> Maybe CoverId -> m (Maybe CoverImage, Items)
parseManifest content coverId = do
  manifest <- findElementE (dfName "manifest") content
  let items = findChildren (dfName "item") manifest
  r <- mapM parseItem items
  let cover = findAttr (emptyName "href") =<< filterChild findCover manifest
  return (T.unpack <$> (cover `mplus` coverId), M.fromList r)
  where
    findCover e = maybe False (T.isInfixOf "cover-image")
                  (findAttr (emptyName "properties") e)
               || Just True == liftM2 (==) coverId (findAttr (emptyName "id") e)
    parseItem e = do
      uid <- findAttrE (emptyName "id") e
      href <- findAttrE (emptyName "href") e
      mime <- findAttrE (emptyName "media-type") e
      return (uid, (T.unpack href, mime))

parseSpine :: PandocMonad m => Items -> Element -> m [(FilePath, MimeType)]
parseSpine is e = do
  spine <- findElementE (dfName "spine") e
  let itemRefs = findChildren (dfName "itemref") spine
  mapM (mkE "parseSpine" . flip M.lookup is) $ mapMaybe parseItemRef itemRefs
  where
    parseItemRef ref = do
      let linear = maybe True (== "yes") (findAttr (emptyName "linear") ref)
      guard linear
      findAttr (emptyName "idref") ref

parseMeta :: PandocMonad m => Element -> m (Maybe CoverId, Meta)
parseMeta content = do
  meta <- findElementE (dfName "metadata") content
  let dcspace (QName _ (Just "http://purl.org/dc/elements/1.1/") (Just "dc")) = True
      dcspace _ = False
  let dcs = filterChildrenName dcspace meta
  let r = foldr parseMetaItem nullMeta dcs
  let coverId = findAttr (emptyName "content") =<< filterChild findCover meta
  return (coverId, r)
  where
    findCover e = findAttr (emptyName "name") e == Just "cover"

-- http://www.idpf.org/epub/30/spec/epub30-publications.html#sec-metadata-elem
parseMetaItem :: Element -> Meta -> Meta
parseMetaItem e@(stripNamespace . elName -> field) meta =
  addMetaField (renameMeta field) (B.str $ strContent e) meta

renameMeta :: Text -> Text
renameMeta "creator" = "author"
renameMeta s         = s

getManifest :: PandocMonad m => Archive -> m (String, Element)
getManifest archive = do
  metaEntry <- findEntryByPathE ("META-INF" </> "container.xml") archive
  docElem <- parseXMLDocE metaEntry
  let namespaces = mapMaybe attrToNSPair (elAttribs docElem)
  ns <- mkE "xmlns not in namespaces" (lookup "xmlns" namespaces)
  as <- fmap (map attrToPair . elAttribs)
    (findElementE (QName "rootfile" (Just ns) Nothing) docElem)
  manifestFile <- T.unpack <$> mkE "Root not found" (lookup "full-path" as)
  let rootdir = dropFileName manifestFile
  --mime <- lookup "media-type" as
  manifest <- findEntryByPathE manifestFile archive
  (rootdir,) <$> parseXMLDocE manifest

-- Fixup

fixInternalReferences :: FilePath -> Pandoc -> Pandoc
fixInternalReferences pathToFile =
   walk (renameImages root)
  . walk (fixBlockIRs filename)
  . walk (fixInlineIRs filename)
  where
    (root, T.unpack . escapeURI . T.pack -> filename) =
      splitFileName pathToFile

fixInlineIRs :: String -> Inline -> Inline
fixInlineIRs s (Span as v) =
  Span (fixAttrs s as) v
fixInlineIRs s (Code as code) =
  Code (fixAttrs s as) code
fixInlineIRs s (Link as is (url, tit)) =
  case parseRelativeReference (T.unpack url) of
    Just URI{ uriScheme = ""
            , uriAuthority = Nothing
            , uriPath = upath
            , uriQuery = ""
            , uriFragment = '#':ufrag } ->
         Link (fixAttrs s as) is (addHash (if null upath
                                              then s
                                              else upath) (T.pack ufrag), tit)
    _ -> Link (fixAttrs s as) is (url, tit)
fixInlineIRs _ v = v

prependHash :: [Text] -> Inline -> Inline
prependHash ps l@(Link attr is (url, tit))
  | or [s `T.isPrefixOf` url | s <- ps] =
    Link attr is ("#" <> url, tit)
  | otherwise = l
prependHash _ i = i

fixBlockIRs :: String -> Block -> Block
fixBlockIRs s (Div as b) =
  Div (fixAttrs s as) b
fixBlockIRs s (Header i as b) =
  Header i (fixAttrs s as) b
fixBlockIRs s (CodeBlock as code) =
  CodeBlock (fixAttrs s as) code
fixBlockIRs _ b = b

fixAttrs :: FilePath -> B.Attr -> B.Attr
fixAttrs s (ident, cs, kvs) =
  (addHash s ident, filter (not . T.null) cs, removeEPUBAttrs kvs)

addHash :: FilePath -> Text -> Text
addHash _ ""    = ""
addHash s ident = T.pack (takeFileName s) <> "_" <> ident

removeEPUBAttrs :: [(Text, Text)] -> [(Text, Text)]
removeEPUBAttrs kvs = filter (not . isEPUBAttr) kvs

isEPUBAttr :: (Text, a) -> Bool
isEPUBAttr (k, _) = "epub:" `T.isPrefixOf` k

-- Library

-- Strict version of foldM
foldM' :: (Monad m, NFData a) => (a -> b -> m a) -> a -> [b] -> m a
foldM' _ z [] = return z
foldM' f z (x:xs) = do
  z' <- f z x
  z' `deepseq` foldM' f z' xs

uncurry3 :: (a -> b -> c -> d) -> (a, b, c) -> d
uncurry3 f (a, b, c) = f a b c

-- Utility

stripNamespace :: QName -> Text
stripNamespace (QName v _ _) = v

attrToNSPair :: Attr -> Maybe (Text, Text)
attrToNSPair (Attr (QName "xmlns" _ _) val) = Just ("xmlns", val)
attrToNSPair _                              = Nothing

attrToPair :: Attr -> (Text, Text)
attrToPair (Attr (QName name _ _) val) = (name, val)

defaultNameSpace :: Maybe Text
defaultNameSpace = Just "http://www.idpf.org/2007/opf"

dfName :: Text -> QName
dfName s = QName s defaultNameSpace Nothing

emptyName :: Text -> QName
emptyName s = QName s Nothing Nothing

-- Convert Maybe interface to Either

findAttrE :: PandocMonad m => QName -> Element -> m Text
findAttrE q e = mkE "findAttr" $ findAttr q e

findEntryByPathE :: PandocMonad m => FilePath -> Archive -> m Entry
findEntryByPathE (normalise . unEscapeString -> path) a =
  mkE ("No entry on path: " <> T.pack path) $ findEntryByPath path a

parseXMLDocE :: PandocMonad m => Entry -> m Element
parseXMLDocE entry =
  either (throwError . PandocXMLError fp) return $ parseXMLElement doc
 where
  doc = UTF8.toTextLazy . fromEntry $ entry
  fp  = T.pack $ eRelativePath entry

findElementE :: PandocMonad m => QName -> Element -> m Element
findElementE e x =
  mkE ("Unable to find element: " <> tshow e) $ findElement e x

mkE :: PandocMonad m => Text -> Maybe a -> m a
mkE s = maybe (throwError . PandocParseError $ s) return
