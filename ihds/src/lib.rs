//! IHDS — Information Handbook and Digest Service.
//!
//! Serves reference data (countries first; cities, languages, currencies
//! later) to the Phoenix app: search-as-you-type, lookup by code, full
//! lists. Data comes only from the versioned seed files in `seed/`; the
//! index is rebuilt in memory from them at every start, so a rebuild is
//! idempotent and the service keeps no state of its own.
//!
//! Design: `docs/design/reference-data-and-files.md`.

pub mod dataset;
pub mod http;
pub mod learned;

pub use dataset::{Catalog, Dataset};
