//! TLS identity for the RDP listener.
//!
//! ClawTank presents a self-signed certificate (users verify it by its SHA-256 fingerprint,
//! shown in the menu). We generate RSA-2048 because it is the most widely accepted key type
//! across stock RDP clients. The Swift host persists the DER blobs in the Keychain and hands
//! them back on every launch, so the fingerprint stays stable.
//!
//! The rustls acceptor is built here, from memory, with an explicit aws-lc-rs provider and
//! no key logging (IronRDP's `helper` module enables `KeyLogFile`, which we do not want).

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest as _, Sha256};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::{
    self,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
};

use crate::Result;

/// Certificate validity for a freshly generated identity.
const VALIDITY_YEARS: i32 = 3;

/// A certificate and its PKCS#8 private key, both DER-encoded.
#[derive(Clone)]
pub struct TlsIdentity {
    pub cert_der: Vec<u8>,
    pub key_pkcs8_der: Vec<u8>,
}

impl std::fmt::Debug for TlsIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsIdentity")
            .field("fingerprint", &self.fingerprint_sha256())
            .finish_non_exhaustive()
    }
}

impl TlsIdentity {
    /// Generates a new self-signed RSA-2048 server certificate for `common_name`.
    pub fn generate(common_name: &str) -> Result<Self> {
        let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_RSA_SHA256)?;
        let mut params = rcgen::CertificateParams::new(vec![common_name.to_owned()])?;
        params.distinguished_name = rcgen::DistinguishedName::new();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, common_name);
        params
            .distinguished_name
            .push(rcgen::DnType::OrganizationName, "ClawTank");
        let year = current_year();
        params.not_before = rcgen::date_time_ymd(year - 1, 1, 1);
        params.not_after = rcgen::date_time_ymd(year + VALIDITY_YEARS, 1, 1);
        params.key_usages = vec![
            rcgen::KeyUsagePurpose::DigitalSignature,
            rcgen::KeyUsagePurpose::KeyEncipherment,
        ];
        params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];

        let cert = params.self_signed(&key)?;
        Ok(Self {
            cert_der: cert.der().to_vec(),
            key_pkcs8_der: key.serialize_der(),
        })
    }

    /// SHA-256 of the certificate DER as uppercase colon-separated hex (`AB:CD:…`), the form
    /// RDP clients display.
    pub fn fingerprint_sha256(&self) -> String {
        let digest = Sha256::digest(&self.cert_der);
        digest
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join(":")
    }

    /// The certificate's SubjectPublicKey bytes, which CredSSP binds to the TLS channel.
    pub fn public_key(&self) -> Result<Vec<u8>> {
        use x509_cert::der::Decode as _;
        let cert = x509_cert::Certificate::from_der(&self.cert_der)?;
        cert.tbs_certificate()
            .subject_public_key_info()
            .subject_public_key
            .as_bytes()
            .map(<[u8]>::to_vec)
            .ok_or_else(|| "certificate public key is not byte-aligned".into())
    }

    /// Builds a TLS acceptor (TLS 1.2 + 1.3, aws-lc-rs, no client auth, no key logging).
    pub fn acceptor(&self) -> Result<TlsAcceptor> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(self.cert_der.clone())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key_pkcs8_der.clone())),
            )?;
        Ok(TlsAcceptor::from(Arc::new(config)))
    }
}

fn current_year() -> i32 {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Average Gregorian year; exact to within a day, which is all a validity window needs.
    1970 + i32::try_from(secs / 31_556_952).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_identity_is_usable() {
        let id = TlsIdentity::generate("test.local").unwrap();
        assert!(
            id.public_key().unwrap().len() > 256,
            "RSA-2048 public key expected"
        );
        id.acceptor().unwrap();
    }

    #[test]
    fn fingerprint_format_is_stable() {
        let id = TlsIdentity::generate("test.local").unwrap();
        let fp = id.fingerprint_sha256();
        assert_eq!(fp.len(), 32 * 3 - 1);
        assert_eq!(fp, id.clone().fingerprint_sha256());
        assert!(fp.chars().all(|c| c == ':' || c.is_ascii_hexdigit()));
    }
}
