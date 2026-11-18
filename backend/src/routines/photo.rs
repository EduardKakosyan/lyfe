//! Photo meals: what the model is asked, how its answer is read, and how
//! the owner's corrections change the figures.
//!
//! Pure rules, no I/O; the asking is in `crate::estimator`. A photo and a
//! one-line description go to a vision model on the Spark, which lists the
//! foods it sees with their grams, kcal and protein. Models pull portions
//! toward a typical serving and miss cooking fat, so the estimate is shown
//! with a range, every item's grams can be corrected, and oil is asked
//! about separately, only for meals the model judged fried, sauced or from
//! a restaurant. The model is told to leave cooking fat and sauce out of
//! its items, so the owner's answer is not counted twice.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::food::{Amount, MAX_NAME_CHARS};

/// The longest one-line description taken.
pub const MAX_NOTE_CHARS: usize = 140;
/// The largest photo taken, in bytes. The phone sends about 300 kB.
pub const MAX_PHOTO_BYTES: usize = 6 * 1024 * 1024;
/// Items in one estimate.
pub const MAX_ITEMS: usize = 20;
/// The heaviest single item, in grams: a big plate of one thing.
pub const MAX_ITEM_GRAMS: f64 = 3_000.0;
/// What "some" oil or sauce adds: about a tablespoon of oil.
pub const OIL_SOME_KCAL: u32 = 120;
/// What "a lot" adds: about three tablespoons.
pub const OIL_A_LOT_KCAL: u32 = 360;
/// Figures the owner types for a whole meal instead of the model's.
pub const MAX_TYPED_KCAL: u32 = 5_000;
pub const MAX_TYPED_PROTEIN_G: f64 = 400.0;
/// How far either way a photo estimate may be, in percent, until the
/// owner's own weighed meals give a better figure.
pub const DEFAULT_RANGE_PCT: u32 = 35;
/// Answers the model may give that cannot be read before lyfe stops
/// asking and lets the owner type the figures.
pub const MAX_TRIES: i32 = 3;

/// How much oil or sauce went into a meal, as the owner answers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Oil {
    None,
    Some,
    ALot,
}

impl Oil {
    pub fn parse(text: &str) -> Option<Oil> {
        match text {
            "none" => Some(Oil::None),
            "some" => Some(Oil::Some),
            "a_lot" => Some(Oil::ALot),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Oil::None => "none",
            Oil::Some => "some",
            Oil::ALot => "a_lot",
        }
    }

    pub fn kcal(self) -> u32 {
        match self {
            Oil::None => 0,
            Oil::Some => OIL_SOME_KCAL,
            Oil::ALot => OIL_A_LOT_KCAL,
        }
    }
}

/// One food the model saw: the grams it judged and its figures for those
/// grams, and the grams that count now, the owner's once corrected.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Item {
    pub name: String,
    pub grams_seen: f64,
    pub kcal_seen: f64,
    pub protein_g_seen: f64,
    /// Zero when the owner says it was not there.
    pub grams: f64,
}

impl Item {
    /// The item's figures at the grams that count: the model's figures
    /// scaled to them.
    fn kcal_and_protein(&self) -> (f64, f64) {
        let share = self.grams / self.grams_seen;
        (self.kcal_seen * share, self.protein_g_seen * share)
    }

    pub fn kcal(&self) -> u32 {
        self.kcal_and_protein().0.round() as u32
    }

    pub fn protein_g(&self) -> f64 {
        (self.kcal_and_protein().1 * 10.0).round() / 10.0
    }
}

/// The oil a meal is counted with: none unless the model asked, and some
/// while the question is unanswered, since cooking fat is what photo
/// estimates miss most.
pub fn oil_counted(oil_asked: bool, oil: Option<Oil>) -> Oil {
    if oil_asked { oil.unwrap_or(Oil::Some) } else { Oil::None }
}

/// What a photo meal comes to: its items at the grams that count, plus the
/// oil or sauce.
pub fn amount(items: &[Item], oil_asked: bool, oil: Option<Oil>) -> Amount {
    let (kcal, protein) = items.iter().fold((0.0, 0.0), |(kcal, protein), item| {
        let (k, p) = item.kcal_and_protein();
        (kcal + k, protein + p)
    });
    Amount {
        kcal: kcal.round() as u32 + oil_counted(oil_asked, oil).kcal(),
        protein_dg: (protein * 10.0).round() as u32,
    }
}

/// The range an estimate of `kcal` may be off by, either way.
pub fn range(kcal: u32, pct: u32) -> (u32, u32) {
    let spread = f64::from(kcal) * f64::from(pct) / 100.0;
    let low = (f64::from(kcal) - spread).max(0.0);
    let high = f64::from(kcal) + spread;
    // To the nearest ten: the range is rough, and reads as rough.
    (((low / 10.0).round() * 10.0) as u32, ((high / 10.0).round() * 10.0) as u32)
}

/// The one line as it is kept: trimmed, and not too long.
pub fn clean_note(text: &str) -> Result<String, &'static str> {
    let note = text.trim();
    if note.chars().count() > MAX_NOTE_CHARS {
        return Err("the note must be at most 140 characters");
    }
    Ok(note.to_string())
}

/// What a photo meal is called on the day: the line typed with it, or a
/// plain name when none was.
pub fn name_for(note: &str) -> String {
    let note = note.trim();
    if note.is_empty() {
        return "Photo meal".into();
    }
    // A name is shorter than a note; the whole note is kept beside it.
    let mut name: String = note.chars().take(MAX_NAME_CHARS).collect();
    if note.chars().count() > MAX_NAME_CHARS {
        name.pop();
        name.push('…');
    }
    name
}

/// Whether bytes are a JPEG, which is all the phone sends.
pub fn is_jpeg(bytes: &[u8]) -> bool {
    bytes.len() > 3 && bytes[..3] == [0xFF, 0xD8, 0xFF]
}

/// The owner's corrected grams, one per item in order, applied to the
/// items, or what is wrong with them.
pub fn correct(items: &[Item], grams: &[f64]) -> Result<Vec<Item>, &'static str> {
    if grams.len() != items.len() {
        return Err("give grams for every item, in order");
    }
    if grams.iter().any(|g| !(g.is_finite() && *g >= 0.0 && *g <= MAX_ITEM_GRAMS)) {
        return Err("an item's grams must be 0 to 3000");
    }
    Ok(items.iter().zip(grams).map(|(item, grams)| Item { grams: *grams, ..item.clone() }).collect())
}

/// Figures the owner typed for the whole meal, or what is wrong with them.
pub fn typed(kcal: u32, protein_g: f64) -> Result<Amount, &'static str> {
    if kcal > MAX_TYPED_KCAL {
        return Err("a meal's kcal must be 0 to 5000");
    }
    if !(protein_g.is_finite() && (0.0..=MAX_TYPED_PROTEIN_G).contains(&protein_g)) {
        return Err("a meal's protein must be 0 to 400 g");
    }
    Ok(Amount { kcal, protein_dg: (protein_g * 10.0).round() as u32 })
}

// --- Asking the model ----------------------------------------------------

/// What the model is told. The owner's line names the food better than a
/// photo shows it, which is the one thing measured to help.
pub fn prompt(note: &str, has_photo: bool) -> String {
    let what = if has_photo {
        "a photo of a meal and the eater's own one-line description of it"
    } else {
        "the eater's own one-line description of a meal (there is no photo)"
    };
    let line = if note.trim().is_empty() { "(none given)".to_string() } else { format!("\"{}\"", note.trim()) };
    format!(
        "You estimate the calories and protein in a meal. You are given {what}.\n\
         Description: {line}\n\n\
         List each food in the meal as eaten, with its weight in grams and the kcal and grams of protein in that \
         weight. Trust the description over the photo for what each food is. Judge portions from the plate, bowl, \
         cutlery and hands in the photo; do not assume a standard serving.\n\
         Leave out oil, butter or fat used in cooking and any sauce or dressing poured over: they are asked about \
         separately. Set fried_sauced_or_restaurant to true when the meal is fried, sautéed, sauced, dressed, or \
         from a restaurant or takeaway, and false otherwise.\n\
         Answer with the JSON object only."
    )
}

/// The shape the model must answer in, as a JSON schema.
pub fn answer_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "grams": {"type": "number"},
                        "kcal": {"type": "number"},
                        "protein_g": {"type": "number"}
                    },
                    "required": ["name", "grams", "kcal", "protein_g"]
                }
            },
            "fried_sauced_or_restaurant": {"type": "boolean"}
        },
        "required": ["items", "fried_sauced_or_restaurant"]
    })
}

/// An estimate as the model gave it, checked.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelEstimate {
    pub items: Vec<Item>,
    pub oil_asked: bool,
}

#[derive(Deserialize)]
struct Answer {
    items: Vec<AnswerItem>,
    fried_sauced_or_restaurant: bool,
}

#[derive(Deserialize)]
struct AnswerItem {
    name: String,
    grams: f64,
    kcal: f64,
    protein_g: f64,
}

/// Reads the model's answer, or says why it cannot be used. An answer with
/// figures no food could have is not used at all, rather than in part.
pub fn read_answer(text: &str) -> Result<ModelEstimate, String> {
    let answer: Answer = serde_json::from_str(text.trim()).map_err(|error| format!("the answer was not the JSON asked for: {error}"))?;
    if answer.items.is_empty() {
        return Err("the answer listed no food".into());
    }
    if answer.items.len() > MAX_ITEMS {
        return Err(format!("the answer listed {} foods; at most {MAX_ITEMS} are taken", answer.items.len()));
    }
    let mut items = Vec::with_capacity(answer.items.len());
    for item in answer.items {
        let name: String = item.name.trim().chars().take(MAX_NAME_CHARS).collect();
        if name.is_empty() {
            return Err("an item had no name".into());
        }
        let finite = item.grams.is_finite() && item.kcal.is_finite() && item.protein_g.is_finite();
        if !finite || item.grams <= 0.0 || item.grams > MAX_ITEM_GRAMS {
            return Err(format!("{name}: {} g is not a portion", item.grams));
        }
        // Pure fat is 9 kcal a gram and nothing is more than all protein.
        if item.kcal < 0.0 || item.kcal > item.grams * 9.0 + 1.0 {
            return Err(format!("{name}: {} kcal in {} g is not possible", item.kcal, item.grams));
        }
        if item.protein_g < 0.0 || item.protein_g > item.grams {
            return Err(format!("{name}: {} g of protein in {} g is not possible", item.protein_g, item.grams));
        }
        items.push(Item {
            name,
            grams_seen: item.grams,
            kcal_seen: item.kcal,
            protein_g_seen: item.protein_g,
            grams: item.grams,
        });
    }
    Ok(ModelEstimate { items, oil_asked: answer.fried_sauced_or_restaurant })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(name: &str, grams: f64, kcal: f64, protein: f64) -> Item {
        Item { name: name.into(), grams_seen: grams, kcal_seen: kcal, protein_g_seen: protein, grams }
    }

    /// The stir fry from the drawn screen: rice and chicken.
    fn stir_fry() -> Vec<Item> {
        vec![item("Rice", 200.0, 260.0, 5.4), item("Chicken", 120.0, 198.0, 27.6)]
    }

    #[test]
    fn a_photo_meal_is_the_sum_of_what_the_model_saw() {
        assert_eq!(amount(&stir_fry(), false, None), Amount { kcal: 458, protein_dg: 330 });
    }

    #[test]
    fn oil_counts_only_when_asked_and_some_until_answered() {
        let items = stir_fry();
        assert_eq!(amount(&items, true, None).kcal, 458 + 120);
        assert_eq!(amount(&items, true, Some(Oil::None)).kcal, 458);
        assert_eq!(amount(&items, true, Some(Oil::Some)).kcal, 578);
        assert_eq!(amount(&items, true, Some(Oil::ALot)).kcal, 458 + 360);
        // Not asked: a salad of plain vegetables gets no oil added.
        assert_eq!(amount(&items, false, Some(Oil::ALot)).kcal, 458);
        // Oil adds no protein.
        assert_eq!(amount(&items, true, Some(Oil::ALot)).protein_dg, 330);
    }

    #[test]
    fn a_corrected_portion_scales_that_items_figures() {
        let corrected = correct(&stir_fry(), &[300.0, 120.0]).unwrap();
        assert_eq!(corrected[0].grams, 300.0);
        assert_eq!(corrected[0].grams_seen, 200.0);
        assert_eq!((corrected[0].kcal(), corrected[0].protein_g()), (390, 8.1));
        assert_eq!(amount(&corrected, false, None), Amount { kcal: 588, protein_dg: 357 });
        // An item that was not there.
        let without = correct(&stir_fry(), &[200.0, 0.0]).unwrap();
        assert_eq!(amount(&without, false, None).kcal, 260);
    }

    #[test]
    fn a_correction_that_makes_no_sense_is_refused() {
        assert!(correct(&stir_fry(), &[300.0]).is_err());
        assert!(correct(&stir_fry(), &[300.0, 120.0, 5.0]).is_err());
        assert!(correct(&stir_fry(), &[-1.0, 120.0]).is_err());
        assert!(correct(&stir_fry(), &[3001.0, 120.0]).is_err());
        assert!(correct(&stir_fry(), &[f64::NAN, 120.0]).is_err());
    }

    #[test]
    fn the_range_is_a_third_either_way_to_the_nearest_ten() {
        assert_eq!(range(590, 35), (380, 800));
        assert_eq!(range(0, 35), (0, 0));
        assert_eq!(range(100, 0), (100, 100));
        assert_eq!(range(100, 150), (0, 250));
    }

    #[test]
    fn typed_figures_must_be_a_meal() {
        assert_eq!(typed(650, 41.5), Ok(Amount { kcal: 650, protein_dg: 415 }));
        assert!(typed(5001, 40.0).is_err());
        assert!(typed(650, -1.0).is_err());
        assert!(typed(650, 401.0).is_err());
        assert!(typed(650, f64::NAN).is_err());
    }

    #[test]
    fn a_photo_meal_is_named_by_its_line() {
        assert_eq!(name_for("  stir fry, rice, some oil "), "stir fry, rice, some oil");
        assert_eq!(name_for(""), "Photo meal");
        let long = "a".repeat(100);
        let name = name_for(&long);
        assert_eq!(name.chars().count(), MAX_NAME_CHARS);
        assert!(name.ends_with('…'));
        assert!(clean_note(&"b".repeat(141)).is_err());
        assert_eq!(clean_note(" pho "), Ok("pho".into()));
    }

    #[test]
    fn only_a_jpeg_is_taken() {
        assert!(is_jpeg(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00]));
        assert!(!is_jpeg(b"\x89PNG\r\n"));
        assert!(!is_jpeg(&[0xFF, 0xD8]));
    }

    #[test]
    fn the_prompt_carries_the_owners_line() {
        let text = prompt(" stir fry, rice ", true);
        assert!(text.contains("Description: \"stir fry, rice\""));
        assert!(text.contains("a photo of a meal"));
        assert!(prompt("", false).contains("(none given)"));
        assert!(prompt("pho", false).contains("there is no photo"));
    }

    #[test]
    fn a_good_answer_is_read() {
        let answer = r#"{"items": [{"name": " Rice ", "grams": 200, "kcal": 260, "protein_g": 5.4},
                                    {"name": "Chicken", "grams": 120, "kcal": 198, "protein_g": 27.6}],
                         "fried_sauced_or_restaurant": true}"#;
        let estimate = read_answer(answer).unwrap();
        assert_eq!(estimate.items, stir_fry());
        assert!(estimate.oil_asked);
    }

    #[test]
    fn an_answer_with_impossible_figures_is_not_used() {
        let one = |item: &str| format!(r#"{{"items": [{item}], "fried_sauced_or_restaurant": false}}"#);
        assert!(read_answer("I think about 600 kcal").is_err());
        assert!(read_answer(r#"{"items": [], "fried_sauced_or_restaurant": false}"#).is_err());
        assert!(read_answer(&one(r#"{"name": "", "grams": 100, "kcal": 100, "protein_g": 1}"#)).is_err());
        assert!(read_answer(&one(r#"{"name": "Rice", "grams": 0, "kcal": 0, "protein_g": 0}"#)).is_err());
        assert!(read_answer(&one(r#"{"name": "Rice", "grams": 5000, "kcal": 100, "protein_g": 1}"#)).is_err());
        // 1000 kcal in 100 g: more than pure fat.
        assert!(read_answer(&one(r#"{"name": "Rice", "grams": 100, "kcal": 1000, "protein_g": 1}"#)).is_err());
        assert!(read_answer(&one(r#"{"name": "Rice", "grams": 100, "kcal": 100, "protein_g": 150}"#)).is_err());
        assert!(read_answer(&one(r#"{"name": "Rice", "grams": 100, "kcal": -5, "protein_g": 1}"#)).is_err());
        let many: Vec<String> =
            (0..21).map(|_| r#"{"name": "Pea", "grams": 1, "kcal": 1, "protein_g": 0.1}"#.to_string()).collect();
        assert!(read_answer(&format!(r#"{{"items": [{}], "fried_sauced_or_restaurant": false}}"#, many.join(","))).is_err());
    }
}
