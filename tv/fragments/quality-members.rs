    // RustDesk 1.5.0 server/video_qos.rs decodes the upper bits as:
    // ratio = ((custom_image_quality >> 8 & 0xFFF) * 2) / 100.
    // 2000 requests ratio 40 (within the official 0.2..40 range).
    // This is an encoder quality/bitrate request, not a fixed Mbps promise.
    fn apply_mate_tv_quality(opt: &mut OptionMessage, image_quality: i32) {
        if image_quality == 2 {
            opt.set_image_quality(ImageQuality::NotSet);
            opt.set_custom_image_quality(2000 << 8);
        } else {
            opt.set_image_quality(Self::image_quality_from_pref(image_quality));
            opt.set_custom_image_quality(0);
        }
    }

