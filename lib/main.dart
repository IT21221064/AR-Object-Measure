import 'package:flutter/material.dart';
import 'ar_ruler_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'AR Ruler', home: const ARRulerPage());
  }
}
