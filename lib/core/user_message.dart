import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 将系统、网络和解析异常转换成中文提示，不向界面暴露英文异常、路径或堆栈。
/// [fallback] 用于未知错误，应由调用方提供当前操作的中文说明。
String userMessage(Object error, {String fallback = '操作失败，请稍后重试'}) {
  if (error is TimeoutException) return '请求超时，请检查网络后重试';
  if (error is SocketException ||
      error is http.ClientException ||
      error is HandshakeException) {
    return '网络连接失败，请检查网络后重试';
  }
  if (error is HttpException) return '网络请求失败，请稍后重试';
  if (error is MissingPluginException) return '当前设备暂不支持此操作';
  if (error is PlatformException) {
    final message = _chineseMessage(error.message);
    if (message != null) return message;
    return switch (error.code) {
      'BAD_URL' => '链接无效，请检查后重试',
      'NO_BROWSER' => '未找到可打开链接的浏览器',
      'BAD_ARGS' => '输入参数无效，请检查坐标和设置',
      'NOT_MOCK_APP' => '请先在开发者选项中选择本应用作为模拟位置应用',
      'NOT_INSTALLED' => '尚未安装目标应用',
      'INVALID_UPDATE' => '安装包校验失败，请重新检查更新',
      'INSTALL_FAILED' => '无法打开安装程序，请稍后重试',
      'INSTALL_PERMISSION' => '请先在系统设置中允许本应用安装更新',
      'UPDATE_FAILED' => '更新失败，请检查网络后重试',
      'NO_PERMISSION' => '尚未获得所需权限，请在系统设置中授权',
      'SETTINGS_UNAVAILABLE' => '无法打开系统设置，请手动进入设置',
      'NATIVE_OPERATION_FAILED' => fallback,
      _ => fallback,
    };
  }
  if (error is FormatException) {
    return _chineseMessage(error.message) ?? '数据格式不正确，请检查后重试';
  }
  final text = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
  if (RegExp(r'\bHTTP\s*\d{3}\b', caseSensitive: false).hasMatch(text)) {
    return '网络请求失败，请稍后重试';
  }
  return _chineseMessage(text) ?? fallback;
}

/// 仅保留简短的中文说明；混合英文、路径和多行异常必须使用受控兜底。
String? _chineseMessage(String? value) {
  final text = value?.trim();
  if (text == null ||
      text.isEmpty ||
      text.length > 160 ||
      !RegExp(r'[\u4e00-\u9fff]').hasMatch(text) ||
      RegExp(r'[A-Za-z/\\\r\n]').hasMatch(text)) {
    return null;
  }
  return text;
}
