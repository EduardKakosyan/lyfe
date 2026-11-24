//! Packaged food: a barcode, the figures on its label, and what the grams
//! eaten come to.
//!
//! Pure rules, no I/O. Codes are looked up in a downloaded food database
//! (Open Food Facts); a code it does not have is typed in once from the
//! label by the owner and remembered. A label's figures are measured, not
//! guessed, so a barcode meal counts as measured.

use serde::Serialize;

use super::food::{Amount, MAX_KCAL_PER_100G, MAX_NAME_CHARS, MAX_PROTEIN_PER_100G};

/// The most grams one entry can be: a whole family pack.
pub const MAX_EATEN_GRAMS: f64 = 3_000.0;
/// The largest serving a label can state.
pub const MAX_SERVING_G: f64 = 2_000.0;

/// Where a product's figures came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    /// Typed from the label by the owner.
    Label,
    /// The downloaded food database.
    Database,
}

/// A packaged food and the figures on its label.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Product {
    pub code: String,
    pub name: String,
    pub kcal_per_100g: f64,
    pub protein_per_100g: f64,
    /// The serving the label states, in grams, when it states one.
    pub serving_g: Option<f64>,
    pub origin: Origin,
}

fn within(value: f64, low: f64, high: f64) -> bool {
    value.is_finite() && value >= low && value <= high
}

impl Product {
    /// A label as the owner typed it, or what is wrong with it.
    pub fn typed(
        code: &str,
        name: &str,
        kcal_per_100g: f64,
        protein_per_100g: f64,
        serving_g: Option<f64>,
    ) -> Result<Product, &'static str> {
        let code = normalize_code(code).ok_or("a barcode is 8 to 14 digits")?;
        let name = name.trim();
        if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
            return Err("the product's name must be 1 to 60 characters");
        }
        if !within(kcal_per_100g, 0.0, MAX_KCAL_PER_100G) {
            return Err("kcal per 100 g must be 0 to 900");
        }
        if !within(protein_per_100g, 0.0, MAX_PROTEIN_PER_100G) {
            return Err("protein per 100 g must be 0 to 100");
        }
        if let Some(serving) = serving_g
            && !(serving.is_finite() && serving > 0.0 && serving <= MAX_SERVING_G)
        {
            return Err("a serving must be above 0 and at most 2000 g");
        }
        Ok(Product {
            code,
            name: name.to_string(),
            kcal_per_100g,
            protein_per_100g,
            serving_g,
            origin: Origin::Label,
        })
    }

    /// What `grams` of it come to.
    pub fn amount(&self, grams: f64) -> Amount {
        Amount {
            kcal: (grams * self.kcal_per_100g / 100.0).round() as u32,
            protein_dg: (grams * self.protein_per_100g / 10.0).round() as u32,
        }
    }
}

/// Whether one entry can be this many grams.
pub fn grams_make_sense(grams: f64) -> bool {
    grams.is_finite() && grams > 0.0 && grams <= MAX_EATEN_GRAMS
}

/// A barcode as it is kept: its digits, from EAN-8 to GTIN-14. Spaces and
/// dashes typed by hand are dropped; anything else is not a barcode.
pub fn normalize_code(text: &str) -> Option<String> {
    let digits: String = text.chars().filter(|c| !c.is_whitespace() && *c != '-').collect();
    (digits.chars().all(|c| c.is_ascii_digit()) && (8..=14).contains(&digits.len())).then_some(digits)
}

/// Every form a code may be stored under. A North American UPC-A of 12
/// digits is the same product as the EAN-13 with a 0 in front, and
/// scanners and databases disagree about which they give.
pub fn lookup_codes(code: &str) -> Vec<String> {
    let mut codes = vec![code.to_string()];
    if code.len() == 12 {
        codes.push(format!("0{code}"));
    }
    if code.len() == 13 && code.starts_with('0') {
        codes.push(code[1..].to_string());
    }
    codes
}

// --- The downloaded database ---------------------------------------------

/// Where the columns lyfe reads are in the Open Food Facts export, which
/// is tab separated with a header line naming each column.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Columns {
    code: usize,
    name: usize,
    kcal: Option<usize>,
    kj: Option<usize>,
    protein: usize,
    serving: Option<usize>,
}

impl Columns {
    /// From the header line, or what it is missing.
    pub fn from_header(line: &str) -> Result<Columns, String> {
        let names: Vec<&str> = line.trim_end_matches(['\r', '\n']).split('\t').collect();
        let find = |name: &str| names.iter().position(|n| *n == name);
        let need = |name: &str| find(name).ok_or_else(|| format!("the file has no {name} column"));
        let columns = Columns {
            code: need("code")?,
            name: need("product_name")?,
            kcal: find("energy-kcal_100g"),
            kj: find("energy_100g"),
            protein: need("proteins_100g")?,
            serving: find("serving_quantity"),
        };
        if columns.kcal.is_none() && columns.kj.is_none() {
            return Err("the file has no energy-kcal_100g or energy_100g column".into());
        }
        Ok(columns)
    }

    /// One product line, or `None` for a line without what lyfe needs: a
    /// barcode, a name, the energy and the protein, all believable.
    pub fn product(&self, line: &str) -> Option<Product> {
        let fields: Vec<&str> = line.trim_end_matches(['\r', '\n']).split('\t').collect();
        let field = |index: usize| fields.get(index).map(|f| f.trim()).filter(|f| !f.is_empty());
        let number = |index: Option<usize>| index.and_then(field).and_then(|f| f.parse::<f64>().ok());

        let code = normalize_code(field(self.code)?)?;
        // Some names carry NUL and other control characters, which the
        // database refuses; they are dropped, and a name left empty skips
        // the line.
        let name: String = field(self.name)?
            .chars()
            .filter(|c| !c.is_control())
            .collect::<String>()
            .trim()
            .chars()
            .take(MAX_NAME_CHARS)
            .collect();
        if name.is_empty() {
            return None;
        }
        // Some lines give only kilojoules.
        let kcal = number(self.kcal).or_else(|| number(self.kj).map(|kj| kj / 4.184))?;
        let protein = number(Some(self.protein))?;
        if !within(kcal, 0.0, MAX_KCAL_PER_100G) || !within(protein, 0.0, MAX_PROTEIN_PER_100G) {
            return None;
        }
        // Protein alone is 4 kcal a gram; a line with more protein than its
        // energy allows has a figure in the wrong place.
        if protein * 4.0 > kcal + 20.0 {
            return None;
        }
        let serving_g = number(self.serving).filter(|g| *g > 0.0 && *g <= MAX_SERVING_G);
        Some(Product {
            code,
            name,
            kcal_per_100g: (kcal * 10.0).round() / 10.0,
            protein_per_100g: (protein * 10.0).round() / 10.0,
            serving_g,
            origin: Origin::Database,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_is_its_digits() {
        assert_eq!(normalize_code("0 64200 11589 6"), Some("064200115896".into()));
        assert_eq!(normalize_code("5449000000996"), Some("5449000000996".into()));
        assert_eq!(normalize_code("96385074"), Some("96385074".into()));
        assert_eq!(normalize_code("1234567"), None);
        assert_eq!(normalize_code("123456789012345"), None);
        assert_eq!(normalize_code("12345678a"), None);
        assert_eq!(normalize_code(""), None);
    }

    #[test]
    fn a_upc_and_its_ean_are_the_same_product() {
        assert_eq!(lookup_codes("064200115896"), vec!["064200115896", "0064200115896"]);
        assert_eq!(lookup_codes("0064200115896"), vec!["0064200115896", "064200115896"]);
        assert_eq!(lookup_codes("5449000000996"), vec!["5449000000996"]);
    }

    #[test]
    fn the_grams_eaten_come_to_the_labels_figures() {
        let bar = Product::typed("96385074", "Protein bar", 350.0, 33.0, Some(60.0)).unwrap();
        assert_eq!(bar.amount(60.0), Amount { kcal: 210, protein_dg: 198 });
        assert_eq!(bar.amount(30.0), Amount { kcal: 105, protein_dg: 99 });
        assert_eq!(bar.origin, Origin::Label);
    }

    #[test]
    fn a_label_that_makes_no_sense_is_refused() {
        let label = |code: &str, name: &str, kcal: f64, protein: f64, serving: Option<f64>| {
            Product::typed(code, name, kcal, protein, serving)
        };
        assert!(label("96385074", "Bar", 350.0, 33.0, None).is_ok());
        assert!(label("963", "Bar", 350.0, 33.0, None).is_err());
        assert!(label("96385074", " ", 350.0, 33.0, None).is_err());
        assert!(label("96385074", "Bar", 3500.0, 33.0, None).is_err());
        assert!(label("96385074", "Bar", 350.0, 330.0, None).is_err());
        assert!(label("96385074", "Bar", 350.0, 33.0, Some(0.0)).is_err());
        assert!(label("96385074", "Bar", 350.0, 33.0, Some(2500.0)).is_err());
        assert!(grams_make_sense(45.0));
        assert!(!grams_make_sense(0.0));
        assert!(!grams_make_sense(3001.0));
    }

    const HEADER: &str = "code\turl\tproduct_name\tserving_quantity\tenergy-kcal_100g\tenergy_100g\tproteins_100g";

    #[test]
    fn a_database_line_is_read_by_its_header() {
        let columns = Columns::from_header(HEADER).unwrap();
        let oats = columns.product("0055577105019\thttps://x\tLarge flake oats\t40\t379\t1586\t13.2\n").unwrap();
        assert_eq!(
            oats,
            Product {
                code: "0055577105019".into(),
                name: "Large flake oats".into(),
                kcal_per_100g: 379.0,
                protein_per_100g: 13.2,
                serving_g: Some(40.0),
                origin: Origin::Database,
            }
        );
        // Only kilojoules given.
        let kj = columns.product("5449000000996\t\tCola\t\t\t180\t0").unwrap();
        assert_eq!((kj.kcal_per_100g, kj.serving_g), (43.0, None));
    }

    #[test]
    fn a_database_line_without_what_lyfe_needs_is_skipped() {
        let columns = Columns::from_header(HEADER).unwrap();
        // No name, no energy, no protein, no barcode.
        assert_eq!(columns.product("0055577105019\t\t\t40\t379\t\t13.2"), None);
        assert_eq!(columns.product("0055577105019\t\tOats\t40\t\t\t13.2"), None);
        assert_eq!(columns.product("0055577105019\t\tOats\t40\t379\t\t"), None);
        assert_eq!(columns.product("\t\tOats\t40\t379\t\t13.2"), None);
        // Figures no food has, or protein the energy does not allow.
        assert_eq!(columns.product("0055577105019\t\tOats\t40\t3790\t\t13.2"), None);
        assert_eq!(columns.product("0055577105019\t\tOats\t40\t37\t\t60"), None);
        // A line cut short.
        assert_eq!(columns.product("0055577105019"), None);
        // A name that is nothing but control characters.
        assert_eq!(columns.product("0055577105019\t\t\u{0}\u{1}\t40\t379\t\t13.2"), None);
    }

    #[test]
    fn control_characters_are_dropped_from_a_name() {
        let columns = Columns::from_header(HEADER).unwrap();
        let oats = columns.product("0055577105019\t\tLarge\u{0} flake oats\u{7f}\t40\t379\t\t13.2").unwrap();
        assert_eq!(oats.name, "Large flake oats");
    }

    #[test]
    fn a_file_without_the_columns_is_refused() {
        assert!(Columns::from_header("code\tproduct_name\tproteins_100g").is_err());
        assert!(Columns::from_header("barcode\tproduct_name\tenergy-kcal_100g\tproteins_100g").is_err());
    }
}
