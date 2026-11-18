//! Meal illustrations: what the image model is asked, and how what the
//! illustrator program answers is read.
//!
//! Pure rules, no I/O; the running is in `crate::illustrator`. A photo
//! meal's picture goes to FLUX.2 klein 4B on the Spark as the image to
//! redraw, with the meal's one line in a fixed prompt that asks for a
//! pictogram on off-white (ADR 0005). The program snaps what it draws to the
//! five Poster colours, so the result sits on the app's paper without a
//! seam. An illustration only ever adds to a meal: the meal is logged and
//! counted without it, and the photo is shown until it comes.

use serde::{Deserialize, Serialize};

/// Times a picture may fail to draw before lyfe stops trying; the photo
/// is shown instead, as it is meanwhile.
pub const MAX_TRIES: i32 = 3;
/// The largest illustration taken back from the program, in bytes. A
/// five-colour PNG of 1024 pixels square is a few hundred kB at most.
pub const MAX_PNG_BYTES: usize = 4 * 1024 * 1024;

/// The prompt that goes with the photo: the round-two pictogram prompt the
/// owner chose in the test on the Spark, with the meal's line in it.
pub fn prompt(note: &str) -> String {
    let what = describe(note);
    format!(
        "Minimal screen-print food poster of {what}. Reduce the meal to a few large bold shapes that still read \
         clearly as each ingredient, like a pictogram. Flat red-orange, cobalt blue, yellow, black and off-white \
         only, no gradients, no outlines thinner than a marker, centred on a plain off-white background, no text."
    )
}

/// The meal as the prompt names it: the owner's line, on one line and
/// without its closing stop, or the photo alone when there is no line.
fn describe(note: &str) -> String {
    let line: String = note
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    let line = line.trim_end_matches(['.', '!', '?', ',', ';', ':', ' ']).trim();
    if line.is_empty() {
        "the meal in this photo".into()
    } else {
        format!("this meal: {line}")
    }
}

/// What lyfe sends the program for one picture, as one line of JSON.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request<'a> {
    pub id: uuid::Uuid,
    pub prompt: &'a str,
    /// The photo as the phone sent it, base64.
    pub jpeg: String,
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
        assert!(prompt.starts_with("Minimal screen-print food poster of this meal: stir fry, rice, some oil. Reduce"), "{prompt}");
        assert!(prompt.contains("centred on a plain off-white background, no text."));
        assert!(prompt.contains("Flat red-orange, cobalt blue, yellow, black and off-white only"));
    }

    #[test]
    fn without_a_line_the_photo_alone_says_what_it_is() {
        assert!(prompt("").starts_with("Minimal screen-print food poster of the meal in this photo. Reduce"));
        assert!(prompt(" ... ").starts_with("Minimal screen-print food poster of the meal in this photo. Reduce"));
        assert!(!prompt("eggs\u{7}").contains('\u{7}'));
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
