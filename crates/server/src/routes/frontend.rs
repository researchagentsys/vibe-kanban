use std::borrow::Cow;

use axum::{
    body::Body,
    http::HeaderValue,
    response::{IntoResponse, Response},
};
use reqwest::{StatusCode, header};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "../../packages/local-web/dist"]
struct Assets;

// The Vite build bakes `/__VKBASE__` (from base=/__VKBASE__/) into every emitted
// asset/chunk URL, the inlined `import.meta.env.BASE_URL`, and the router
// basepath. At serve time we replace it with the configured deploy prefix so a
// single image works behind any reverse-proxy path:
//   VK_PUBLIC_PATH unset    -> ""      : /__VKBASE__/assets -> /assets   (root, standalone)
//   VK_PUBLIC_PATH=/cs/<id>/ -> /cs/<id> : /__VKBASE__/assets -> /cs/<id>/assets
const BASE_PLACEHOLDER: &str = "/__VKBASE__";

fn base_replacement() -> String {
    std::env::var("VK_PUBLIC_PATH")
        .map(|p| p.trim_end_matches('/').to_string())
        .unwrap_or_default()
}

// Only text assets carry the placeholder; binaries (images/fonts) are byte-served.
fn needs_base_subst(path: &str) -> bool {
    path.ends_with(".html")
        || path.ends_with(".js")
        || path.ends_with(".mjs")
        || path.ends_with(".css")
}

fn body_for(path: &str, data: Cow<'static, [u8]>) -> Body {
    if needs_base_subst(path) {
        let replaced =
            String::from_utf8_lossy(&data).replace(BASE_PLACEHOLDER, &base_replacement());
        Body::from(replaced.into_bytes())
    } else {
        Body::from(data.into_owned())
    }
}

pub(super) async fn serve_frontend(uri: axum::extract::Path<String>) -> impl IntoResponse {
    let path = uri.trim_start_matches('/');
    serve_file(path).await
}

pub(super) async fn serve_frontend_root() -> impl IntoResponse {
    serve_file("index.html").await
}

async fn serve_file(path: &str) -> impl IntoResponse + use<> {
    match Assets::get(path) {
        Some(content) => {
            let mime = mime_guess::from_path(path).first_or_octet_stream();

            Response::builder()
                .status(StatusCode::OK)
                .header(
                    header::CONTENT_TYPE,
                    HeaderValue::from_str(mime.as_ref()).unwrap(),
                )
                .body(body_for(path, content.data))
                .unwrap()
        }
        None => {
            // For SPA routing, serve index.html for unknown routes (base-substituted).
            if let Some(index) = Assets::get("index.html") {
                Response::builder()
                    .status(StatusCode::OK)
                    .header(header::CONTENT_TYPE, HeaderValue::from_static("text/html"))
                    .body(body_for("index.html", index.data))
                    .unwrap()
            } else {
                Response::builder()
                    .status(StatusCode::NOT_FOUND)
                    .body(Body::from("404 Not Found"))
                    .unwrap()
            }
        }
    }
}
