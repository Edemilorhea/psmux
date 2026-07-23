use super::{normalize_local_send_key, parse_command_line, parse_local_send_keys_args};

#[test]
fn local_send_keys_routes_named_and_modifier_keys_through_shared_dispatch() {
    assert_eq!(normalize_local_send_key("Escape").as_deref(), Some("esc"));
    assert_eq!(normalize_local_send_key("PPAGE").as_deref(), Some("pageup"));
    assert_eq!(normalize_local_send_key("f12").as_deref(), Some("f12"));
    assert_eq!(normalize_local_send_key("c-M-x").as_deref(), Some("C-M-x"));
    assert_eq!(normalize_local_send_key("M-C-x").as_deref(), Some("C-M-x"));
    assert_eq!(normalize_local_send_key("C-S--").as_deref(), Some("C-S--"));
}

#[test]
fn local_send_keys_preserves_modifier_character_case_and_unicode() {
    assert_eq!(normalize_local_send_key("M-F").as_deref(), Some("M-F"));
    assert_eq!(normalize_local_send_key("M-é").as_deref(), Some("M-é"));
    assert_eq!(normalize_local_send_key("C-?").as_deref(), Some("C-?"));
}

#[test]
fn local_send_keys_leaves_plain_text_on_the_text_path() {
    assert_eq!(normalize_local_send_key("hello"), None);
    assert_eq!(normalize_local_send_key("S-a"), None);
    assert_eq!(normalize_local_send_key("-la"), None);
}

#[test]
fn local_send_keys_parses_value_flags_repeat_and_dash_prefixed_text() {
    let parts = ["send-keys", "-t", "0", "-N", "5", "Up"];
    let (_, _, repeat, keys) = parse_local_send_keys_args(&parts);
    assert_eq!(repeat, 5);
    assert_eq!(keys, ["Up"]);

    let parts = ["send-keys", "--", "-la"];
    let (_, _, repeat, keys) = parse_local_send_keys_args(&parts);
    assert_eq!(repeat, 1);
    assert_eq!(keys, ["-la"]);
}

#[test]
fn local_send_keys_uses_quote_aware_command_parsing() {
    let parsed = parse_command_line(r#"send-keys "ls -la" Enter"#);
    let parts: Vec<&str> = parsed.iter().map(String::as_str).collect();
    let (literal, _, _, keys) = parse_local_send_keys_args(&parts);
    assert!(!literal);
    assert_eq!(keys, ["ls -la", "Enter"]);

    let parsed = parse_command_line(r#"send-keys -l "literal text""#);
    let parts: Vec<&str> = parsed.iter().map(String::as_str).collect();
    let (literal, _, _, keys) = parse_local_send_keys_args(&parts);
    assert!(literal);
    assert_eq!(keys, ["literal text"]);
}

#[test]
fn ctrl_alt_native_payload_uses_send_keys_control_mapping() {
    let ctrl_slash = crate::input::ctrl_char_send_keys_byte('/').unwrap();
    assert_eq!(ctrl_slash, 0x1f);
    assert_eq!(
        crate::platform::modified_key_u_char('/', true, false, Some(ctrl_slash as u16)),
        Some(0x1f),
    );
    assert_eq!(crate::input::ctrl_char_send_keys_byte('$'), None);
}

#[test]
fn native_meta_payload_rejects_non_bmp_characters() {
    assert_eq!(
        crate::platform::modified_key_u_char('😀', false, false, None),
        None,
    );
}
