#[cfg(test)]
mod mate_tv_quality_tests {
    use super::*;

    #[test]
    fn high_bandwidth_quality_survives_wire_serialization() {
        let mut options = OptionMessage::new();
        Session::apply_mate_tv_quality(&mut options, 2);
        let encoded = options.write_to_bytes().unwrap();
        let decoded: OptionMessage = protobuf::parse_from_bytes(&encoded).unwrap();
        // The host consults custom_image_quality ONLY if image_quality is NotSet.
        assert_eq!(decoded.get_image_quality(), ImageQuality::NotSet);
        let ratio = ((decoded.get_custom_image_quality() >> 8 & 0xFFF) * 2) as f32 / 100.0;
        assert_eq!(ratio, 20.0);
        assert_eq!(decoded.get_custom_fps(), 0);
        assert!(!decoded.has_supported_decoding());
    }

    #[test]
    fn lower_bandwidth_presets_clear_previous_custom_quality() {
        let mut options = OptionMessage::new();
        for (preference, expected) in [(1, ImageQuality::Balanced), (0, ImageQuality::Low)] {
            Session::apply_mate_tv_quality(&mut options, 2);
            Session::apply_mate_tv_quality(&mut options, preference);
            assert_eq!(options.get_image_quality(), expected);
            assert_eq!(options.get_custom_image_quality(), 0);
        }
    }
}
