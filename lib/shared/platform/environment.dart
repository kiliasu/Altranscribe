import 'dart:io';

/// An override from the environment. An empty value counts as unset, because
/// some shells leave variables behind empty after a script restores them.
String? environmentValue(String name, {Map<String, String>? environment}) {
  final value = (environment ?? Platform.environment)[name];
  return value == null || value.isEmpty ? null : value;
}
