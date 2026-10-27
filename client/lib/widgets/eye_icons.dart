import 'package:flutter/material.dart';

/// The one show / hide pair: the Events list's eye toggle and the
/// timeline lane menu's Hide use exactly these, so they read as one control
/// (eye: shown on the timeline and counted in the balance; eye-off: hidden
/// and excluded from the balance, the event's `enabled` flag).
const IconData eventShownIcon = Icons.visibility_outlined;
const IconData eventHiddenIcon = Icons.visibility_off_outlined;
