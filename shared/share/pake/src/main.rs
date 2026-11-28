//! Local CPace adapter. No socket, filesystem, trust-store or UI access.
//! All messages are fixed-size over private stdio. Never export the PAKE key.
#![forbid(unsafe_code)]

use pake_cpace::{ChannelIdentifier, NoAD, SessionAD, CPace};
use std::io::{self, Read, Write};
use zeroize::Zeroizing;

const DOMAIN: &[u8] = b"pulse-share/pair-cpace-draft06/v1";

fn emit(w: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    w.write_all(bytes)?;
    w.flush()
}

fn take<const N: usize>(r: &mut impl Read) -> io::Result<[u8; N]> {
    let mut b = [0; N];
    r.read_exact(&mut b)?;
    Ok(b)
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "pair authentication failed")
}

fn exchange(r: &mut impl Read, w: &mut impl Write) -> io::Result<()> {
    // PSP1, role (0 initiator, 1 responder), 8 digit password,
    // initiator certificate pin, responder certificate pin, TLS exporter.
    if take::<4>(r)? != *b"PSP1" {
        return Err(invalid());
    }
    let role = take::<1>(r)?[0];
    let password = Zeroizing::new(take::<8>(r)?);
    if role > 1 || !password.iter().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    let a = take::<32>(r)?;
    let b = take::<32>(r)?;
    let exporter = take::<32>(r)?;
    if a == b {
        return Err(invalid());
    }
    let extra: [&[u8]; 2] = [DOMAIN, &exporter];
    let channel = ChannelIdentifier {
        id_a: &a,
        id_b: &b,
        extra_context: &extra,
    };
    let mut sid = [0; 16];
    sid.copy_from_slice(&exporter[..16]);

    let negotiation = if role == 0 {
        let state = CPace::new(&sid, &password[..], &channel, &SessionAD { session_id: sid })
            .map_err(|_| invalid())?;
        emit(w, state.message())?;
        let peer = take::<32>(r)?.to_vec();
        state
            .initiator_process_message::<NoAD>(peer)
            .map_err(|_| invalid())?
            .0
    } else {
        let peer = take::<48>(r)?.to_vec();
        let (message, ad) = CPace::responder_process_message::<SessionAD>(peer)
            .map_err(|_| invalid())?;
        if ad.session_id != sid {
            return Err(invalid());
        }
        let state = CPace::new(&sid, &password[..], &channel, &NoAD {})
            .map_err(|_| invalid())?;
        emit(w, state.message())?;
        message.finish(state).map_err(|_| invalid())?
    };

    emit(w, &negotiation.tag())?;
    let peer_tag = take::<64>(r)?;
    let _key = Zeroizing::new(negotiation.verify_tag(&peer_tag).map_err(|_| invalid())?);
    emit(w, &[1])
}

fn main() -> std::process::ExitCode {
    let mut r = io::stdin().lock();
    let mut w = io::stdout().lock();
    match exchange(&mut r, &mut w) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        // Never print password, key, library debug output or peer input.
        Err(_) => std::process::ExitCode::FAILURE,
    }
}
