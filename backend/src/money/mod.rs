//! Client for SimpleFIN Bridge, which holds the owner's bank connections
//! and hands lyfe a read-only view of them: accounts, balances and posted
//! transactions. The bridge pushes nothing and refreshes about once a day,
//! so lyfe asks a few times a day and never more (it allows about 24
//! requests a day and switches off an access that goes far past that).
//!
//! lyfe never sees a bank password. What it holds is the access address
//! the bridge issued, which carries its own user name and password; that
//! stays in a file on the Spark and never appears in logs, errors or
//! stored state.

pub mod ledger;
pub mod sync;

use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;
use serde_json::Value;

/// The bridges an access address or a setup token may point at. A token is
/// pasted in by hand, and lyfe sends nothing to an address it does not
/// know.
const BRIDGE_HOSTS: [&str; 2] = ["bridge.simplefin.org", "beta-bridge.simplefin.org"];

/// The most days lyfe asks the bridge for in one request. The bridge
/// answers for up to 90 but says that more than 45 is more than it would
/// like and may one day be refused.
pub const MAX_RANGE_DAYS: i64 = 45;

/// Errors are worded for the owner: they are stored and shown as the
/// reason an import failed, and contain nothing secret.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BridgeError {
    #[error("the SimpleFIN access file is missing or unreadable")]
    AccessUnreadable,
    #[error("the SimpleFIN access file does not hold an access address")]
    AccessInvalid,
    #[error("SimpleFIN refused the access; it may have been revoked, so connect again")]
    AccessRejected,
    #[error("SimpleFIN says the subscription needs paying")]
    PaymentDue,
    #[error("SimpleFIN answered with HTTP {0}")]
    Status(u16),
    #[error("SimpleFIN could not be reached")]
    Unreachable,
    #[error("SimpleFIN's answer could not be understood")]
    BadResponse,
    #[error("that is not a SimpleFIN setup token")]
    TokenInvalid,
    #[error("SimpleFIN did not accept the setup token; it may have been used already, so make a new one")]
    TokenRejected,
}

/// Where the bridge is asked and as whom, read from the access address.
#[derive(Clone, PartialEq, Eq)]
struct Access {
    /// The address without the user name and password, no trailing slash.
    base: String,
    username: String,
    password: String,
}

impl Access {
    /// Reads `https://user:password@bridge/simplefin`.
    fn parse(text: &str) -> Option<Access> {
        let url = checked(text.trim())?;
        let username = percent_decoded(url.username())?;
        let password = percent_decoded(url.password()?)?;
        if username.is_empty() || password.is_empty() || url.query().is_some() || url.fragment().is_some() {
            return None;
        }
        let mut base = url.clone();
        base.set_username("").ok()?;
        base.set_password(None).ok()?;
        Some(Access { base: base.as_str().trim_end_matches('/').to_string(), username, password })
    }
}

/// An address lyfe is willing to talk to: one of the bridges over HTTPS,
/// or this machine itself, which is where the tests stand one in.
fn checked(text: &str) -> Option<reqwest::Url> {
    let url = reqwest::Url::parse(text).ok()?;
    let host = url.host_str()?;
    let local = matches!(host, "127.0.0.1" | "localhost" | "[::1]");
    let known = url.scheme() == "https" && BRIDGE_HOSTS.contains(&host) && matches!(url.port(), None | Some(443));
    (known || local).then_some(url)
}

fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' {
            let hex = text.get(at + 1..at + 3)?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            decoded.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

/// One sign-in at one bank.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Connection {
    pub id: String,
    pub name: String,
}

/// Something the bridge said went wrong, in its words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trouble {
    /// `gen.`, `con.` or `act.` and what follows, as the bridge codes it;
    /// empty for a plain line with no code.
    pub code: String,
    pub text: String,
    pub connection_id: Option<String>,
    pub account_id: Option<String>,
}

impl Trouble {
    /// True when the owner has to sign in to the bank again at the bridge.
    pub fn needs_reconnecting(code: &str) -> bool {
        code == "con.auth"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BankAccount {
    pub connection_id: String,
    pub id: String,
    pub name: String,
    pub currency: String,
    pub balance_minor: i64,
    pub available_minor: Option<i64>,
    pub balance_at: DateTime<Utc>,
    /// True when the bank lists what the account holds: an investment
    /// account, which lyfe sets aside from the start.
    pub holds_investments: bool,
    pub transactions: Vec<BankTransaction>,
    /// Transactions that could not be read and were left out.
    pub unreadable: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BankTransaction {
    pub id: String,
    pub posted_at: DateTime<Utc>,
    /// When it happened, where the bank says.
    pub transacted_at: Option<DateTime<Utc>>,
    pub amount_minor: i64,
    pub payee: String,
    pub description: String,
    pub memo: String,
}

/// One answer from the bridge.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AccountSet {
    pub connections: Vec<Connection>,
    pub accounts: Vec<BankAccount>,
    pub troubles: Vec<Trouble>,
    /// Accounts that could not be read (no id, or a currency that is not a
    /// plain three-letter code) and were left out.
    pub unreadable_accounts: usize,
}

pub struct BridgeClient {
    http: reqwest::Client,
    access_file: PathBuf,
}

impl BridgeClient {
    pub fn new(access_file: PathBuf) -> anyhow::Result<Self> {
        Ok(Self { http: http()?, access_file })
    }

    /// Accounts with their balances, and the transactions posted from
    /// `from` up to but not including `until`: at most `MAX_RANGE_DAYS`.
    pub async fn accounts(&self, from: DateTime<Utc>, until: DateTime<Utc>) -> Result<AccountSet, BridgeError> {
        let text = tokio::fs::read_to_string(&self.access_file).await.map_err(|_| BridgeError::AccessUnreadable)?;
        let access = Access::parse(&text).ok_or(BridgeError::AccessInvalid)?;
        let response = self
            .http
            .get(format!("{}/accounts", access.base))
            .basic_auth(&access.username, Some(&access.password))
            .header(reqwest::header::ACCEPT, "application/json")
            .query(&[
                ("version", "2".to_string()),
                ("start-date", from.timestamp().to_string()),
                ("end-date", until.timestamp().to_string()),
            ])
            .send()
            .await
            .map_err(|_| BridgeError::Unreachable)?;
        match response.status().as_u16() {
            200 => {}
            402 => return Err(BridgeError::PaymentDue),
            401 | 403 => return Err(BridgeError::AccessRejected),
            other => return Err(BridgeError::Status(other)),
        }
        let body: Value = response.json().await.map_err(|_| BridgeError::BadResponse)?;
        parse_account_set(&body).ok_or(BridgeError::BadResponse)
    }
}

fn http() -> reqwest::Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .user_agent("lyfe-server")
        // The bridge may send a request on to another of its addresses,
        // and nowhere else is ever followed to.
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() < 3 && checked(attempt.url().as_str()).is_some() {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
}

/// Trades a setup token, made once at the bridge, for the access address.
/// A token works once: after this it is spent whether or not the answer
/// is kept.
pub async fn claim(setup_token: &str) -> Result<String, BridgeError> {
    let compact: String = setup_token.split_whitespace().collect();
    let decoded = base64::engine::general_purpose::STANDARD_NO_PAD
        .decode(compact.trim_end_matches('='))
        .map_err(|_| BridgeError::TokenInvalid)?;
    let claim_url = String::from_utf8(decoded).map_err(|_| BridgeError::TokenInvalid)?;
    let url = checked(claim_url.trim()).ok_or(BridgeError::TokenInvalid)?;
    if !url.username().is_empty() || !url.path().contains("/claim/") {
        return Err(BridgeError::TokenInvalid);
    }
    let response = http()
        .map_err(|_| BridgeError::Unreachable)?
        .post(url)
        .header(reqwest::header::CONTENT_LENGTH, "0")
        .send()
        .await
        .map_err(|_| BridgeError::Unreachable)?;
    match response.status().as_u16() {
        200 => {}
        403 => return Err(BridgeError::TokenRejected),
        other => return Err(BridgeError::Status(other)),
    }
    let access = response.text().await.map_err(|_| BridgeError::BadResponse)?;
    let access = access.trim().to_string();
    Access::parse(&access).ok_or(BridgeError::BadResponse)?;
    Ok(access)
}

/// True when `text` is an access address lyfe can use.
pub fn is_access_address(text: &str) -> bool {
    Access::parse(text).is_some()
}

// --- Reading an answer -----------------------------------------------------

#[derive(Deserialize)]
struct RawTrouble {
    #[serde(default)]
    code: String,
    #[serde(default)]
    msg: String,
    conn_id: Option<String>,
    account_id: Option<String>,
}

/// Reads what lyfe needs out of an answer. Lenient about what is missing
/// or extra, since the bridge's second version of the format is young: an
/// account or a transaction that cannot be read is counted and left out,
/// and only an answer with no account list at all is refused.
pub fn parse_account_set(body: &Value) -> Option<AccountSet> {
    let object = body.as_object()?;
    let accounts = object.get("accounts")?.as_array()?;
    let mut set = AccountSet::default();

    for connection in object.get("connections").and_then(Value::as_array).into_iter().flatten() {
        let Some(id) = text(connection.get("conn_id")) else { continue };
        let name = text(connection.get("name")).or_else(|| text(connection.get("org_name"))).unwrap_or_default();
        set.connections.push(Connection { id, name: ledger::shown(&name, 60) });
    }

    let coded: Vec<RawTrouble> = object
        .get("errlist")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| serde_json::from_value(item.clone()).ok())
        .collect();
    if coded.is_empty() {
        // The older form: plain lines, with nothing to say what they are about.
        for line in object.get("errors").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            let line = ledger::shown(line, 200);
            if !line.is_empty() {
                set.troubles.push(Trouble { code: String::new(), text: line, connection_id: None, account_id: None });
            }
        }
    }
    for trouble in coded {
        let said = ledger::shown(&trouble.msg, 200);
        set.troubles.push(Trouble {
            text: if said.is_empty() { "Something went wrong at the bank.".to_string() } else { said },
            code: ledger::shown(&trouble.code, 40),
            connection_id: trouble.conn_id.filter(|id| !id.is_empty()),
            account_id: trouble.account_id.filter(|id| !id.is_empty()),
        });
    }

    for account in accounts {
        match parse_account(account) {
            Some((account, connection)) => {
                // Before version 2 there was no list of connections: the
                // account carried its bank.
                if !set.connections.iter().any(|known| known.id == account.connection_id) {
                    set.connections.push(Connection { id: account.connection_id.clone(), name: connection });
                }
                set.accounts.push(account);
            }
            None => set.unreadable_accounts += 1,
        }
    }
    for connection in &mut set.connections {
        if connection.name.is_empty() {
            connection.name = "Bank".to_string();
        }
    }
    Some(set)
}

fn parse_account(value: &Value) -> Option<(BankAccount, String)> {
    let object = value.as_object()?;
    let id = text(object.get("id"))?;
    let organisation = object.get("org");
    let connection_id = text(object.get("conn_id"))
        .or_else(|| text(organisation.and_then(|org| org.get("id"))))
        .or_else(|| text(organisation.and_then(|org| org.get("domain"))))?;
    let connection_name = text(object.get("conn_name"))
        .or_else(|| text(organisation.and_then(|org| org.get("name"))))
        .or_else(|| text(organisation.and_then(|org| org.get("domain"))))
        .unwrap_or_default();
    let currency = text(object.get("currency"))?;
    if currency.len() != 3 || !currency.chars().all(|c| c.is_ascii_uppercase()) {
        return None;
    }
    let balance_minor = amount(object.get("balance"))?;
    let balance_at = time(object.get("balance-date"))?;
    let name = ledger::shown(&text(object.get("name")).unwrap_or_default(), 60);

    let mut transactions = Vec::new();
    let mut unreadable = 0;
    for item in object.get("transactions").and_then(Value::as_array).into_iter().flatten() {
        // Only what has posted is kept. A pending charge can change or
        // vanish, and is not asked for; one that comes anyway is skipped.
        if item.get("pending").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        match parse_transaction(item) {
            Some(transaction) => transactions.push(transaction),
            None => unreadable += 1,
        }
    }
    Some((
        BankAccount {
            connection_id,
            id,
            name: if name.is_empty() { "Account".to_string() } else { name },
            currency,
            balance_minor,
            available_minor: amount(object.get("available-balance")),
            balance_at,
            holds_investments: object.get("holdings").and_then(Value::as_array).is_some_and(|held| !held.is_empty()),
            transactions,
            unreadable,
        },
        ledger::shown(&connection_name, 60),
    ))
}

fn parse_transaction(value: &Value) -> Option<BankTransaction> {
    let object = value.as_object()?;
    let line = |name: &str| ledger::shown(object.get(name).and_then(Value::as_str).unwrap_or_default(), 200);
    let amount_minor = amount(object.get("amount")).filter(|minor| *minor != 0)?;
    Some(BankTransaction {
        id: text(object.get("id"))?,
        posted_at: time(object.get("posted"))?,
        transacted_at: time(object.get("transacted_at")),
        amount_minor,
        payee: line("payee"),
        description: line("description"),
        memo: line("memo"),
    })
}

/// A non-empty string, or a number written out.
fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn amount(value: Option<&Value>) -> Option<i64> {
    ledger::minor_units(&text(value)?)
}

/// A time in seconds since 1970. Zero is how the bridge writes "not known".
fn time(value: Option<&Value>) -> Option<DateTime<Utc>> {
    let seconds = match value? {
        Value::Number(number) => number.as_i64().or_else(|| number.as_f64().map(|f| f as i64))?,
        Value::String(text) => text.trim().parse().ok()?,
        _ => return None,
    };
    (seconds > 0).then(|| Utc.timestamp_opt(seconds, 0).single()).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_access_address_is_taken_apart() {
        let access = Access::parse("https://demo%40user:p%3Ass@beta-bridge.simplefin.org/simplefin\n").unwrap();
        assert_eq!(access.base, "https://beta-bridge.simplefin.org/simplefin");
        assert_eq!((access.username.as_str(), access.password.as_str()), ("demo@user", "p:ss"));
        assert!(Access::parse("http://user:pass@127.0.0.1:9000/simplefin/").is_some_and(|a| a.base == "http://127.0.0.1:9000/simplefin"));
        for wrong in [
            "",
            "not an address",
            "https://beta-bridge.simplefin.org/simplefin",
            "https://user@beta-bridge.simplefin.org/simplefin",
            "http://user:pass@beta-bridge.simplefin.org/simplefin",
            "https://user:pass@elsewhere.example/simplefin",
            "https://user:pass@beta-bridge.simplefin.org:8443/simplefin",
            "https://user:pass@beta-bridge.simplefin.org/simplefin?x=1",
        ] {
            assert!(Access::parse(wrong).is_none(), "{wrong}");
        }
    }

    #[tokio::test]
    async fn a_token_that_points_somewhere_else_is_not_followed() {
        let encode = |text: &str| base64::engine::general_purpose::STANDARD.encode(text);
        for wrong in [
            "!!!".to_string(),
            encode("not an address"),
            encode("https://elsewhere.example/simplefin/claim/abc"),
            encode("http://bridge.simplefin.org/simplefin/claim/abc"),
            encode("https://user:pass@bridge.simplefin.org/simplefin/claim/abc"),
            encode("https://bridge.simplefin.org/simplefin/accounts"),
        ] {
            assert_eq!(claim(&wrong).await, Err(BridgeError::TokenInvalid), "{wrong}");
        }
    }

    #[test]
    fn an_answer_is_read_with_its_connections_and_troubles() {
        let set = parse_account_set(&json!({
            "errlist": [
                {"code": "con.auth", "msg": "Sign in\nagain at First Bank", "conn_id": "CON-1"},
                {"code": "act.missingdata", "msg": "Some transactions are missing", "account_id": "ACT-2"},
                {"code": "gen.api", "msg": ""}
            ],
            "errors": ["Sign in again at First Bank"],
            "connections": [{"conn_id": "CON-1", "name": "First Bank", "org_id": "ORG-1", "sfin_url": "https://x.invalid"}],
            "accounts": [
                {"id": "ACT-1", "name": "Chequing", "conn_id": "CON-1", "currency": "CAD",
                 "balance": "1250.07", "available-balance": "1200.00", "balance-date": 1795000000,
                 "transactions": [
                    {"id": "T1", "posted": 1794900000, "transacted_at": 1794800000, "amount": "-12.50",
                     "description": "POS CORNER GROCER 0031", "payee": "Corner Grocer", "memo": ""},
                    {"id": "T2", "posted": 0, "amount": "-3.00", "description": "Coffee", "pending": true},
                    {"id": "T3", "posted": 1794900000, "amount": "0.00", "description": "Nothing"},
                    {"posted": 1794900000, "amount": "5.00", "description": "No id"}
                 ]},
                {"id": "ACT-2", "name": "", "conn_id": "CON-2", "conn_name": "Second Bank", "currency": "CAD",
                 "balance": -310.4, "balance-date": 1795000000, "holdings": [{"id": "H1", "symbol": "XYZ"}]},
                {"id": "ACT-3", "name": "Points", "conn_id": "CON-1", "currency": "https://x.invalid/points",
                 "balance": "10", "balance-date": 1795000000},
                {"name": "No id", "currency": "CAD", "balance": "1", "balance-date": 1795000000}
            ]
        }))
        .unwrap();
        assert_eq!(
            set.connections,
            vec![
                Connection { id: "CON-1".into(), name: "First Bank".into() },
                Connection { id: "CON-2".into(), name: "Second Bank".into() },
            ]
        );
        assert_eq!(set.unreadable_accounts, 2);
        let chequing = &set.accounts[0];
        assert_eq!((chequing.balance_minor, chequing.available_minor), (125007, Some(120000)));
        assert_eq!(chequing.balance_at.timestamp(), 1795000000);
        assert_eq!(chequing.unreadable, 2);
        assert_eq!(
            chequing.transactions,
            vec![BankTransaction {
                id: "T1".into(),
                posted_at: Utc.timestamp_opt(1794900000, 0).unwrap(),
                transacted_at: Some(Utc.timestamp_opt(1794800000, 0).unwrap()),
                amount_minor: -1250,
                payee: "Corner Grocer".into(),
                description: "POS CORNER GROCER 0031".into(),
                memo: String::new(),
            }]
        );
        let card = &set.accounts[1];
        assert_eq!((card.name.as_str(), card.balance_minor, card.available_minor), ("Account", -31040, None));
        assert_eq!((chequing.holds_investments, card.holds_investments), (false, true));
        // The coded list wins over the plain lines, and is made safe to show.
        assert_eq!(set.troubles.len(), 3);
        assert_eq!(set.troubles[0].text, "Sign in again at First Bank");
        assert_eq!(set.troubles[0].connection_id.as_deref(), Some("CON-1"));
        assert!(Trouble::needs_reconnecting(&set.troubles[0].code));
        assert_eq!(set.troubles[1].account_id.as_deref(), Some("ACT-2"));
        assert_eq!(set.troubles[2].text, "Something went wrong at the bank.");
    }

    #[test]
    fn the_older_form_of_answer_is_read_too() {
        let set = parse_account_set(&json!({
            "errors": ["You are asking too often"],
            "accounts": [{"org": {"domain": "firstbank.example", "name": "First Bank"}, "id": "A", "name": "Chequing",
                          "currency": "CAD", "balance": "10.00", "balance-date": 1795000000, "transactions": []}]
        }))
        .unwrap();
        assert_eq!(set.connections, vec![Connection { id: "firstbank.example".into(), name: "First Bank".into() }]);
        assert_eq!(set.troubles.len(), 1);
        assert_eq!((set.troubles[0].code.as_str(), set.troubles[0].text.as_str()), ("", "You are asking too often"));
        assert_eq!(parse_account_set(&json!({"errors": []})), None);
        assert_eq!(parse_account_set(&json!("nope")), None);
    }
}
