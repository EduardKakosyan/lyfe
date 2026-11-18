//! lyfe backend: the single authority for routines, streaks and targets.
//! Clients capture and display; everything that must agree lives here.

pub mod api;
pub mod auth;
pub mod config;
pub mod db;
pub mod garmin;
pub mod push;
pub mod routines;
