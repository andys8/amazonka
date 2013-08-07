{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.AWS.XML
-- Copyright   : (c) 2013 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Data.Aeson.XML
    ( fromXML
    ) where

import           Control.Applicative
import           Control.Category         (id)
import           Data.Aeson
import qualified Data.HashMap.Strict      as HashMap
import qualified Data.Map                 as Map
import           Data.Maybe
import qualified Data.Text                as T
import           Data.Tree.NTree.TypeDefs
import qualified Data.Vector              as V
import           Prelude                  hiding (id)
import           Text.XML.HXT.Core
import           Text.XML.HXT.Expat       (withExpat)

data JSValue = Text | Tag String | Attr String
    deriving (Eq, Ord, Show)

fromXML :: FromJSON a => String -> IO (Maybe a)
fromXML src = do
    elems <- runX $ flip readString src
        [ withValidate no
        , withCheckNamespaces no
        , withParseByMimeType no
        , withExpat yes
        ] >>> getChildren

    print $ encode <$> map (unWrap . treeToJSON) elems

    return . decodeFirst $ encode <$> map (unWrap . treeToJSON) elems
  where
    unWrap (Just (_, x)) = x -- object [(packJSValue a, b)]
    unWrap Nothing       = Null

    decodeFirst (x:_) = decode x
    decodeFirst _     = Nothing

--
-- Internal
--

treeToJSON :: XmlTree -> Maybe (JSValue, Value)
treeToJSON node
    | (NTree (XText str) _)     <- node = text str
    | (NTree (XTag qName _) cs) <- node = tag qName cs
    | otherwise                        = Nothing
  where
    text "" = Nothing
    text s  = Just (Text, String . T.strip $ T.pack s)

    tag qName cs = Just (Tag (localPart qName), mapToJSValue $ objMap cs)

    objMap cs = arrayValuesToJSON     -- unify into a single map,
        . concatValues                -- grouping into arrays by pair name
        . map (uncurry Map.singleton) -- convert pairs to maps
        . (++) attrValues             -- attributes turned into normal pairs
        . catMaybes                   -- filter out the empty values (unconvertable nodes)
        $ map treeToJSON cs           -- convert xml nodes to Maybe (QName, Value) pairs

    arrayValuesToJSON = Map.mapMaybe f
      where
        f []  = Nothing                        -- will be discarded
        f [x] = Just x                         -- don't store as array, just a single value
        f xs  = Just $ Array . V.fromList $ xs -- arrays with more than one element are kept

    attrValues = map (Attr *** String . T.pack) $
        runLA (getAttrl >>> getName &&& (getChildren >>> getText)) node

    concatValues = Map.unionsWith (++) . (fmap . fmap) (: [])

    mapToJSValue m
        | Map.null m = Array V.empty -- convert empty elements to empty arrays
        | otherwise  =  case Map.toList m of
              [(Text, val)] -> val
              _             -> Object
                  . HashMap.fromList
                  . (map . first) packJSValue
                  $ Map.toList m

packJSValue :: JSValue -> T.Text
packJSValue Text     = T.pack "value"
packJSValue (Attr x) = T.pack x
packJSValue (Tag x)  = T.pack x
