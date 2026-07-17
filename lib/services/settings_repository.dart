import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../models/return_feed_config.dart';

/// JSON-in-SharedPreferences persistence for presets and settings.
class SettingsRepository {
  static const _presetsKey = 'destination_presets';
  static const _defaultPresetKey = 'default_preset_id';
  static const _encoderKey = 'encoder_settings';
  static const _cameraKey = 'camera_settings';
  static const _returnFeedKey = 'return_feed_config';

  Future<List<DestinationPreset>> loadPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_presetsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => DestinationPreset.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }

  Future<void> savePresets(List<DestinationPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_presetsKey, jsonEncode(presets.map((p) => p.toJson()).toList()));
  }

  Future<String?> loadDefaultPresetId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultPresetKey);
  }

  Future<void> saveDefaultPresetId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_defaultPresetKey);
    } else {
      await prefs.setString(_defaultPresetKey, id);
    }
  }

  Future<EncoderSettings> loadEncoderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_encoderKey);
    if (raw == null) return const EncoderSettings();
    return EncoderSettings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveEncoderSettings(EncoderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_encoderKey, jsonEncode(settings.toJson()));
  }

  Future<CameraSettings> loadCameraSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cameraKey);
    if (raw == null) return const CameraSettings();
    return CameraSettings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveCameraSettings(CameraSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cameraKey, jsonEncode(settings.toJson()));
  }

  Future<ReturnFeedConfig> loadReturnFeedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_returnFeedKey);
    if (raw == null) return const ReturnFeedConfig();
    return ReturnFeedConfig.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveReturnFeedConfig(ReturnFeedConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_returnFeedKey, jsonEncode(config.toJson()));
  }
}
