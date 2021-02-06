{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeApplications #-}

module Frontend where

import Common.Api (EmanoteApi (..), EmanoteNet)
import Common.Route
import Control.Monad.Fix (MonadFix)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Constraint.Extras (Has)
import Data.Tagged
import qualified Data.Text as T
import Emanote.Markdown.WikiLink
import Obelisk.Configs (getTextConfig)
import Obelisk.Frontend
import Obelisk.Generated.Static (static)
import Obelisk.Route
import Obelisk.Route.Frontend
import Reflex.Dom.Core
import Reflex.Dom.GadtApi
import qualified Reflex.Dom.Pandoc as PR
import Relude

type ValidEnc = Encoder Identity Identity (R (FullRoute BackendRoute FrontendRoute)) PageName

-- This runs in a monad that can be run on the client or the server.
-- To run code in a pure client or pure server context, use one of the
-- `prerender` functions.
frontend :: Frontend (R FrontendRoute)
frontend =
  Frontend
    { _frontend_head = do
        el "title" $ text "Emanote"
        elAttr "link" ("href" =: static @"main.css" <> "type" =: "text/css" <> "rel" =: "stylesheet") blank,
      _frontend_body = do
        el "h1" $ text "Emanote"
        let enc :: Either Text ValidEnc = checkEncoder fullRouteEncoder
        route <- getTextConfig "common/route"
        case (enc, route) of
          (Left _, _) -> error "Routes are invalid!"
          (_, Nothing) -> error "Couldn't load common/route config file"
          (Right validEnc, Just host) -> do
            let _endpoint =
                  Right $
                    T.replace "http" "ws" host
                      <> renderBackendRoute validEnc (BackendRoute_WebSocket :/ ())
                endpoint =
                  Left $ renderBackendRoute validEnc (BackendRoute_Api :/ ())
            r :: Dynamic t (R FrontendRoute) <- askRoute
            startEmanoteNet endpoint $ flip runRoutedT r app
    }

startEmanoteNet ::
  forall js t m.
  ( Prerender js t m,
    MonadHold t m,
    MonadFix m,
    Has FromJSON EmanoteApi,
    forall a. ToJSON (EmanoteApi a)
  ) =>
  Either ApiEndpoint WebSocketEndpoint ->
  EmanoteNet t m () ->
  m ()
startEmanoteNet endpoint f = do
  rec (_, requests) <- runRequesterT f $ responses
      responses <- case endpoint of
        Left xhr -> performXhrRequests xhr (requests :: Event t (RequesterData EmanoteApi))
        Right ws -> performWebSocketRequests ws (requests :: Event t (RequesterData EmanoteApi))
  pure ()

app ::
  forall t m js.
  ( DomBuilder t m,
    MonadHold t m,
    MonadFix m,
    Prerender js t m,
    RouteToUrl (R FrontendRoute) m,
    SetRoute t (R FrontendRoute) m,
    Response m ~ Either Text,
    Request m ~ EmanoteApi,
    Requester t m
  ) =>
  RoutedT t (R FrontendRoute) m ()
app = do
  subRoute_ $ \case
    FrontendRoute_Main -> do
      req <- fmap (const EmanoteApi_GetNotes) <$> askRoute
      resp <- requestingDynamic req
      widgetHold_ (text "Loading...") $
        ffor resp $ \case
          Left (err :: Text) -> text (show err)
          Right notes ->
            el "ul" $ do
              forM_ notes $ \wId -> do
                el "li" $ do
                  routeLink (FrontendRoute_Note :/ wId) $ text $ untag wId
    FrontendRoute_Note -> do
      req <- fmap EmanoteApi_Note <$> askRoute
      resp <- requestingDynamic req
      widgetHold_ (text "Loading...") $
        ffor resp $ \case
          Left err -> text (show err)
          Right Nothing -> text "No such note"
          Right (Just (Left conflict)) -> text (show conflict)
          Right (Just (Right (_fp, Left parseErr))) -> text (show parseErr)
          Right (Just (Right (_fp, Right doc))) -> do
            let cfg =
                  PR.defaultConfig
                    { PR._config_renderLink = linkRender
                    }
            PR.elPandoc cfg doc
  where
    linkRender defRender url _minner =
      fromMaybe defRender $ do
        let mtitle = Nothing -- TODO
        (_lbl, wId) <- parseWikiLinkUrl mtitle url
        pure $ routeLink (FrontendRoute_Note :/ wId) $ text $ untag wId

-- | Like @requesting@, but takes a Dynamic instead.
requestingDynamic ::
  (Requester t m, MonadSample t m, Prerender js t m) =>
  Dynamic t (Request m a) ->
  m (Event t (Response m a))
requestingDynamic reqDyn = do
  r0 <- sample $ current reqDyn
  let rE = updated reqDyn
  requesting <=< fmap switchPromptlyDyn $ do
    prerender (pure never) $ do
      pb <- getPostBuild
      pure $ leftmost [r0 <$ pb, rE]