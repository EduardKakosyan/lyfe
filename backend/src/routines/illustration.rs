//! Meal illustrations: what the image model is asked, and how what the
//! illustrator program answers is read.
//!
//! Pure rules, no I/O; the running is in `crate::illustrator`. A photo
//! meal's picture goes to FLUX.2 klein 4B on the Spark as the image to
//! redraw, with the meal's one line in a fixed prompt (ADR 0005, and for
//! the look ADR 0006): the meal as it is, in its own colours, with black
//! ink outlines and only its dish in a Poster colour. The program sets the
//! background to the app's paper, so the result sits on the screen without
//! a box around it. An illustration only ever adds to a meal: the meal is
//! logged and counted without it, and the photo is shown until it comes.
//!
//! The same model draws the icons of the foods in the ingredient catalogue,
//! from a food's name alone, with no photo (ADR 0008): the food by itself,
//! in its own colours, with the same ink outlines, on the same paper.

use serde::{Deserialize, Serialize};

/// Times a picture may fail to draw before lyfe stops trying; the photo
/// is shown instead, as it is meanwhile.
pub const MAX_TRIES: i32 = 3;
/// The largest illustration taken back from the program, in bytes. One of
/// 768 pixels square in 64 colours is about 100 kB.
pub const MAX_PNG_BYTES: usize = 4 * 1024 * 1024;

/// The look this prompt draws, counted up whenever the prompt or the
/// program's finishing changes what a drawing looks like. Photos drawn in
/// an earlier look are drawn again (see `db::redraw_older_looks`).
pub const LOOK: i32 = 2;

/// The prompt that goes with the photo, with the meal's line in it: the
/// look the owner chose from two rounds on the Spark, on their own photos.
/// It keeps the meal recognisable, where the first look, a pictogram in
/// five colours, did not.
pub fn prompt(note: &str) -> String {
    let what = describe(note);
    format!(
        "Redraw this photo of {what} as a bold flat graphic illustration with thick black ink outlines and flat \
         colour fills, no gradients. The food and drink keep exactly their natural colours. Only the cup, plate or \
         bowl changes colour: draw it in one flat poster colour, cobalt blue, red-orange or yellow, whichever \
         stands out most against the food. Draw only the main dish and the food or drink in it, with the same \
         shapes, proportions and viewpoint as the photo, so it is instantly recognisable. Leave out everything \
         else: no table, tray, cutlery, glasses, shakers, napkins, phones or laptops. Centred on a plain off-white \
         background. No text."
    )
}

/// The look food icons are drawn in, counted up whenever `icon_prompt` or
/// the program's finishing changes what an icon looks like. An icon drawn
/// in an earlier look is drawn again the next time the phone asks for it.
pub const ICON_LOOK: i32 = 1;
/// The longest food name an icon is drawn for. The catalogue's are at most
/// 60 characters.
pub const MAX_ICON_NAME_LENGTH: usize = 80;

/// The prompt a food's icon is drawn from, with no photo: its name as the
/// catalogue has it, which says how it is prepared ("Potato, baked"). The
/// wording is the one that did best in six rounds on the Spark. "A serving
/// of" is what keeps "Chicken, broiler, wing" from being drawn as a hen;
/// saying what to leave out does not work, since whatever the prompt names
/// is drawn.
pub fn icon_prompt(name: &str) -> String {
    let food = describe(name);
    format!(
        "Flat vector illustration of a serving of {food}, as a simple food icon. Thick black ink outline, bold flat natural \
         colours, no shading, no gradients, no white border. Isolated and centred on a plain off-white \
         background, filling most of the picture. No text."
    )
}

/// What a food's icon is kept by: its name on one line and in lower case,
/// so the same food asked for twice is drawn once. None for a name no icon
/// is drawn for: an empty one, or one too long to be a food's.
pub fn icon_key(name: &str) -> Option<String> {
    let line: String = name.split_whitespace().collect::<Vec<_>>().join(" ").chars().filter(|c| !c.is_control()).collect();
    let key = line.trim().to_lowercase();
    (!key.is_empty() && key.chars().count() <= MAX_ICON_NAME_LENGTH).then_some(key)
}

/// The meal as the prompt names it: the owner's line, on one line and
/// without its closing stop, or just a meal when there is no line.
fn describe(note: &str) -> String {
    let line: String = note
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    let line = line.trim_end_matches(['.', '!', '?', ',', ';', ':', ' ']).trim();
    if line.is_empty() { "a meal".into() } else { line.to_string() }
}

/// What lyfe sends the program for one picture, as one line of JSON.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request<'a> {
    pub id: uuid::Uuid,
    pub prompt: &'a str,
    /// The photo to redraw, as the phone sent it, base64. Left out for a
    /// food's icon, which is drawn from the prompt alone, and smaller.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jpeg: Option<String>,
}

/// The first line the program writes, once the model is loaded or it has
/// given up loading it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Ready {
    pub ready: bool,
    #[serde(default)]
    pub error: Option<String>,
    /// How long loading took.
    #[serde(default)]
    pub seconds: Option<f64>,
}

/// The program's answer for one picture, as it writes it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
struct Answer {
    id: Option<uuid::Uuid>,
    png: Option<String>,
    error: Option<String>,
}

/// One picture drawn.
#[derive(Debug, Clone, PartialEq)]
pub struct Drawn {
    pub png: Vec<u8>,
}

/// Reads the program's answer for the picture `id`: the illustration, or
/// why there is none, in words.
pub fn read_answer(line: &str, id: uuid::Uuid) -> Result<Drawn, String> {
    let answer: Answer = serde_json::from_str(line.trim()).map_err(|_| "the illustrator's answer was not JSON".to_string())?;
    if answer.id != Some(id) {
        return Err("the illustrator answered for another picture".into());
    }
    if let Some(error) = answer.error {
        return Err(format!("the illustrator could not draw it: {}", first_line(&error)));
    }
    let text = answer.png.ok_or("the illustrator's answer had no picture")?;
    let png = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, text.trim())
        .map_err(|_| "the illustrator's picture was not base64".to_string())?;
    if png.len() > MAX_PNG_BYTES {
        return Err("the illustrator's picture was too large".into());
    }
    if !is_png(&png) {
        return Err("the illustrator's picture was not a PNG".into());
    }
    Ok(Drawn { png })
}

/// Reads the program's first line.
pub fn read_ready(line: &str) -> Result<Ready, String> {
    let ready: Ready =
        serde_json::from_str(line.trim()).map_err(|_| format!("the illustrator said something else: {}", first_line(line)))?;
    if !ready.ready {
        let why = ready.error.as_deref().map(first_line).unwrap_or_else(|| "no reason given".into());
        return Err(format!("the illustrator could not load the model: {why}"));
    }
    Ok(ready)
}

pub fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(b"\x89PNG\r\n\x1a\n")
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().chars().take(200).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    fn encoded(bytes: &[u8]) -> String {
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes)
    }

    #[test]
    fn the_prompt_names_the_meal_by_its_line() {
        let prompt = prompt("  stir fry,\n rice, some oil. ");
        assert!(prompt.starts_with("Redraw this photo of stir fry, rice, some oil as a bold flat graphic illustration"), "{prompt}");
        assert!(prompt.contains("The food and drink keep exactly their natural colours."));
        assert!(prompt.contains("Only the cup, plate or bowl changes colour"));
        assert!(prompt.ends_with("Centred on a plain off-white background. No text."));
    }

    #[test]
    fn without_a_line_the_photo_alone_says_what_it_is() {
        assert!(prompt("").starts_with("Redraw this photo of a meal as a bold flat"));
        assert!(prompt(" ... ").starts_with("Redraw this photo of a meal as a bold flat"));
        assert!(!prompt("eggs\u{7}").contains('\u{7}'));
    }

    #[test]
    fn an_icon_is_asked_for_by_the_foods_name_alone() {
        let prompt = icon_prompt(" Potato,\n baked. ");
        assert!(prompt.starts_with("Flat vector illustration of a serving of Potato, baked, as a simple food icon."), "{prompt}");
        assert!(prompt.contains("Thick black ink outline, bold flat natural colours"));
        assert!(prompt.ends_with("on a plain off-white background, filling most of the picture. No text."));
        // With no photo, the request has none.
        let id = uuid::Uuid::from_u128(7);
        let line = serde_json::to_string(&Request { id, prompt: "p", jpeg: None }).unwrap();
        assert_eq!(line, format!(r#"{{"id":"{id}","prompt":"p"}}"#));
        let line = serde_json::to_string(&Request { id, prompt: "p", jpeg: Some("QQ==".into()) }).unwrap();
        assert_eq!(line, format!(r#"{{"id":"{id}","prompt":"p","jpeg":"QQ=="}}"#));
    }

    #[test]
    fn an_icon_is_kept_by_the_foods_name_however_it_is_spelled() {
        assert_eq!(icon_key("  Potato,\n  BAKED "), Some("potato, baked".into()));
        assert_eq!(icon_key("Crème fraîche\u{7}"), Some("crème fraîche".into()));
        assert_eq!(icon_key(" \n "), None);
        assert_eq!(icon_key(&"x".repeat(MAX_ICON_NAME_LENGTH)), Some("x".repeat(MAX_ICON_NAME_LENGTH)));
        assert_eq!(icon_key(&"x".repeat(MAX_ICON_NAME_LENGTH + 1)), None);
    }

    #[test]
    fn a_drawn_picture_is_read_back() {
        let id = uuid::Uuid::from_u128(7);
        let line = format!(r#"{{"id": "{id}", "png": "{}", "seconds": 7.1}}"#, encoded(PNG));
        assert_eq!(read_answer(&line, id), Ok(Drawn { png: PNG.to_vec() }));
    }

    #[test]
    fn an_answer_that_is_not_a_picture_says_why() {
        let id = uuid::Uuid::from_u128(7);
        let other = uuid::Uuid::from_u128(8);
        assert_eq!(read_answer("not json", id), Err("the illustrator's answer was not JSON".into()));
        assert_eq!(
            read_answer(&format!(r#"{{"id": "{other}", "png": "{}"}}"#, encoded(PNG)), id),
            Err("the illustrator answered for another picture".into())
        );
        assert_eq!(
            read_answer(&format!(r#"{{"id": "{id}", "error": "cannot identify image file\nTraceback"}}"#), id),
            Err("the illustrator could not draw it: cannot identify image file".into())
        );
        assert_eq!(
            read_answer(&format!(r#"{{"id": "{id}", "png": "{}"}}"#, encoded(b"GIF89a")), id),
            Err("the illustrator's picture was not a PNG".into())
        );
        assert_eq!(read_answer(&format!(r#"{{"id": "{id}", "png": "%%%"}}"#), id), Err("the illustrator's picture was not base64".into()));
        assert_eq!(read_answer(&format!(r#"{{"id": "{id}"}}"#), id), Err("the illustrator's answer had no picture".into()));
    }

    #[test]
    fn the_first_line_says_whether_the_model_loaded() {
        assert_eq!(read_ready(r#"{"ready": true, "seconds": 93.5}"#).unwrap().seconds, Some(93.5));
        assert_eq!(
            read_ready(r#"{"ready": false, "error": "CUDA out of memory"}"#),
            Err("the illustrator could not load the model: CUDA out of memory".into())
        );
        assert_eq!(read_ready("Traceback (most recent call last):"), Err("the illustrator said something else: Traceback (most recent call last):".into()));
    }
}
