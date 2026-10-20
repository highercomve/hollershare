//! Allocation-free admission checks for protobuf's repeated message fields.
//! A wire-size limit alone does not bound the size of decoded empty messages.
use anyhow::{anyhow, bail, Result};
use prost::encoding::{decode_key, decode_varint, skip_field, DecodeContext, WireType};
use prost::Message;

use crate::sharing_nearby::Frame;

pub(super) const MAX_METADATA_ENTRIES: usize = 1024;
const MAX_CERTIFICATES: usize = 128;

pub(super) fn decode_sharing_frame(data: &[u8]) -> Result<Frame> {
    if data.len() > super::SANE_FRAME_LENGTH as usize {
        bail!("Sharing frame too large");
    }
    let mut remaining = data;
    let mut metadata = 0;
    let mut certificates = 0;
    // Each iteration consumes at least a key byte; all slices borrow the
    // size-limited input. Duplicate singular envelopes merge in prost, so
    // their repeated-field budgets must be shared across the entire frame.
    while !remaining.is_empty() {
        let (tag, wire) = decode_key(&mut remaining)?;
        if tag == 2 {
            check_v1(
                message_bytes(wire, &mut remaining)?,
                &mut metadata,
                &mut certificates,
            )?;
        } else {
            skip_field(wire, tag, &mut remaining, DecodeContext::default())?;
        }
    }
    Ok(Frame::decode(data)?)
}

fn check_v1(mut data: &[u8], metadata: &mut usize, certificates: &mut usize) -> Result<()> {
    while !data.is_empty() {
        let (tag, wire) = decode_key(&mut data)?;
        match tag {
            2 => check_entries(
                message_bytes(wire, &mut data)?,
                &[1, 2, 4],
                metadata,
                MAX_METADATA_ENTRIES,
            )?,
            6 => check_entries(
                message_bytes(wire, &mut data)?,
                &[1],
                certificates,
                MAX_CERTIFICATES,
            )?,
            _ => skip_field(wire, tag, &mut data, DecodeContext::default())?,
        }
    }
    Ok(())
}

fn check_entries(mut data: &[u8], tags: &[u32], count: &mut usize, limit: usize) -> Result<()> {
    while !data.is_empty() {
        let (tag, wire) = decode_key(&mut data)?;
        if tags.contains(&tag) {
            if *count == limit {
                bail!("Too many sharing metadata entries or certificates");
            }
            *count += 1;
            message_bytes(wire, &mut data)?;
        } else {
            skip_field(wire, tag, &mut data, DecodeContext::default())?;
        }
    }
    Ok(())
}

fn message_bytes<'a>(wire: WireType, data: &mut &'a [u8]) -> Result<&'a [u8]> {
    if wire != WireType::LengthDelimited {
        bail!("Invalid protobuf message wire type");
    }
    let length = usize::try_from(decode_varint(data)?)?;
    let message = data
        .get(..length)
        .ok_or_else(|| anyhow!("Truncated protobuf message"))?;
    *data = &data[length..];
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::encoding::{encode_key, encode_varint};

    fn field(tag: u32, bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        encode_key(tag, WireType::LengthDelimited, &mut out);
        encode_varint(bytes.len() as u64, &mut out);
        out.extend_from_slice(bytes);
        out
    }

    #[test]
    fn bounds_all_repeated_message_kinds_before_decode() {
        for tag in [1, 2, 4] {
            let entries = field(tag, &[]).repeat(MAX_METADATA_ENTRIES);
            let frame = field(2, &field(2, &entries));
            assert!(decode_sharing_frame(&frame).is_ok());
            let bomb = field(2, &field(2, &field(tag, &[]).repeat(100_000)));
            assert!(decode_sharing_frame(&bomb).is_err());
        }
        let certs = field(1, &[]).repeat(MAX_CERTIFICATES + 1);
        assert!(decode_sharing_frame(&field(2, &field(6, &certs))).is_err());
    }

    #[test]
    fn duplicate_envelopes_cannot_reset_budgets() {
        let intro = field(2, &field(1, &[]).repeat(MAX_METADATA_ENTRIES / 2 + 1));
        assert!(decode_sharing_frame(&field(2, &intro).repeat(2)).is_err());
        assert!(decode_sharing_frame(&field(2, &intro.repeat(2))).is_err());
    }

    #[test]
    fn rejects_bad_lengths_and_wire_types_but_allows_unknown_fields() {
        for bytes in [&[0x12, 0x80][..], &[0x12, 4, 0][..], &[0x10, 0][..]] {
            assert!(decode_sharing_frame(bytes).is_err());
        }
        assert!(decode_sharing_frame(&field(99, b"future extension")).is_ok());
        assert!(
            decode_sharing_frame(&vec![0; super::super::SANE_FRAME_LENGTH as usize + 1]).is_err()
        );
    }
}
