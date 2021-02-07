{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE TypeApplications #-}

module Frontend where

import Common.Api
import Common.Route
import Control.Monad.Fix (MonadFix)
import qualified Data.Map.Strict as Map
import Data.Tagged
import Emanote.Markdown.WikiLink
import qualified Frontend.App as App
import Obelisk.Frontend
import Obelisk.Generated.Static (static)
import Obelisk.Route
import Obelisk.Route.Frontend
import Reflex.Dom.Core
import qualified Reflex.Dom.Pandoc as PR
import Relude

-- This runs in a monad that can be run on the client or the server.
-- To run code in a pure client or pure server context, use one of the
-- `prerender` functions.
frontend :: Frontend (R FrontendRoute)
frontend =
  Frontend
    { _frontend_head = do
        elAttr "meta" ("content" =: "text/html; charset=utf-8" <> "http-equiv" =: "Content-Type") blank
        elAttr "meta" ("content" =: "width=device-width, initial-scale=1" <> "name" =: "viewport") blank
        el "title" $ text "Emanote"
        elAttr "link" ("href" =: static @"main-compiled.css" <> "type" =: "text/css" <> "rel" =: "stylesheet") blank,
      _frontend_body = do
        divClass "min-h-screen md:container mx-auto px-4" $ do
          App.runApp app
    }

app ::
  forall t m js.
  ( DomBuilder t m,
    MonadHold t m,
    PostBuild t m,
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
      el "h1" $ text "Emanote"
      req <- fmap (const EmanoteApi_GetNotes) <$> askRoute
      resp <- App.requestingDynamic req
      widgetHold_ loader $
        ffor resp $ \case
          Left (err :: Text) -> text (show err)
          Right notes -> do
            el "ul" $ do
              forM_ notes $ \wId -> do
                el "li" $ do
                  routeLink (FrontendRoute_Note :/ wId) $ text $ untag wId
    FrontendRoute_Note -> do
      req <- fmap EmanoteApi_Note <$> askRoute
      resp <- App.requestingDynamic req
      waiting <-
        holdDyn True $
          leftmost
            [ fmap (const True) (updated req),
              fmap (const False) resp
            ]
      elDynClass "div" (ffor waiting $ bool "" "animate-pulse") $ do
        mresp <- maybeDyn =<< holdDyn Nothing (Just <$> resp)
        dyn_ $
          ffor mresp $ \case
            Nothing -> loader
            Just resp' -> do
              eresp <- eitherDyn resp'
              dyn_ $
                ffor eresp $ \case
                  Left errDyn -> dynText $ show <$> errDyn
                  Right (noteDyn :: Dynamic t Note) -> do
                    divClass "grid gap-4 grid-cols-6" $ do
                      divClass "col-start-1 col-span-2" $ do
                        divClass "linksBox p-2" $ do
                          routeLink (FrontendRoute_Main :/ ()) $ text "Back to /"
                        divClass "linksBox animated" $ do
                          renderLinkContexts "Uplinks" (_note_uplinks <$> noteDyn) $ \ctx -> do
                            divClass "opacity-50 hover:opacity-100 text-sm" $ do
                              dyn_ $ renderPandoc <$> ctx
                        divClass "linksBox animated" $ do
                          renderLinkContexts "Backlinks" (_note_backlinks <$> noteDyn) $ \ctx -> do
                            divClass "opacity-50 hover:opacity-100 text-sm" $ do
                              dyn_ $ renderPandoc <$> ctx
                      divClass "col-start-3 col-span-4" $ do
                        el "h1" $ do
                          r <- askRoute
                          dynText $ untag <$> r
                        mzettel <- maybeDyn $ _note_zettel <$> noteDyn
                        dyn_ $
                          ffor mzettel $ \case
                            Nothing -> text "No such note"
                            Just zDyn -> do
                              ez <- eitherDyn zDyn
                              dyn_ $
                                ffor ez $ \case
                                  Left conflict -> dynText $ show <$> conflict
                                  Right (fmap snd -> v) -> do
                                    edoc <- eitherDyn v
                                    dyn_ $
                                      ffor edoc $ \case
                                        Left parseErr -> dynText $ show <$> parseErr
                                        Right docDyn -> do
                                          dyn_ $ renderPandoc <$> docDyn
                        divClass "" $ do
                          divClass "linksBox animated" $ do
                            renderLinkContexts "Downlinks" (_note_downlinks <$> noteDyn) $ \ctx -> do
                              divClass "opacity-50 hover:opacity-100 text-sm" $ do
                                dyn_ $ renderPandoc <$> ctx
                          -- Adding a bg color only to workaround a font jankiness
                          divClass "linksBox overflow-auto max-h-60 bg-gray-200" $ do
                            renderLinkContexts "Orphans" (_note_orphans <$> noteDyn) (const blank)
                      divClass "col-start-1 col-span-6 place-self-center text-gray-400 border-t-2" $ do
                        text "Powered by "
                        elAttr "a" ("href" =: "https://github.com/srid/emanote") $
                          text "Emanote"
  where
    renderLinkContexts name ls ctxW = do
      divClass name $ do
        elClass "h2" "header w-full pl-2 pt-2 pb-2 font-serif bg-green-100 " $ text name
        divClass "p-2" $ do
          void $
            simpleList ls $ \lDyn -> do
              divClass "pt-1" $ do
                divClass "linkheader" $
                  renderLinkContext ("class" =: "text-green-700") lDyn
                ctxW $ _linkcontext_ctx <$> lDyn
    renderLinkContext attrs lDyn = do
      routeLinkDynAttr
        ( ffor lDyn $ \LinkContext {..} ->
            "title" =: show _linkcontext_label <> attrs
        )
        ( ffor lDyn $ \LinkContext {..} ->
            FrontendRoute_Note :/ _linkcontext_id
        )
        $ do
          dynText $ untag . _linkcontext_id <$> lDyn

    -- FIXME: doesn't work
    _iconBack :: DomBuilder t m1 => m1 ()
    _iconBack = do
      elAttr
        "svg"
        ( "xmlns" =: "http://www.w3.org/2000/svg"
            <> "fill" =: "none"
            <> "viewBox" =: "0 0 24 24"
            <> "stroke" =: "currentColor"
        )
        $ do
          elAttr
            "path"
            ( "stroke-linecap" =: "round"
                <> "stroke-linejoin" =: "round"
                <> "stroke-width" =: "2"
                <> "d" =: "M11 15l-3-3m0 0l3-3m-3 3h8M3 12a9 9 0 1118 0 9 9 0 01-18 0z"
            )
            blank
    renderPandoc doc = do
      let cfg =
            PR.defaultConfig
              { PR._config_renderLink = linkRender
              }
      PR.elPandoc cfg doc
    linkRender defRender url attrs _minner =
      fromMaybe defRender $ do
        (lbl, wId) <- parseWikiLinkUrl (Map.lookup "title" attrs) url
        pure $ do
          let r = constDyn $ FrontendRoute_Note :/ wId
              attr = constDyn $ "title" =: show lbl
          routeLinkDynAttr attr r $ do
            text $ untag wId

loader :: DomBuilder t m => m ()
loader = do
  text "Loading..."
