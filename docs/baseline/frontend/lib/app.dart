import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'pages/home_page.dart';

class EasyLearnApp extends StatelessWidget {
  const EasyLearnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: '伴学',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
