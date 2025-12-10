import 'package:flutter/material.dart';

class GradientAppBarTitle extends StatelessWidget {
  final String text;
  final double fontSize;

  const GradientAppBarTitle(
    this.text, {
    Key? key,
    this.fontSize = 20,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) {
        return const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xFF8AB4FF), // blue
            Color(0xFFC084FC), // purple
            Color(0xFF60A5FA), // sky
          ],
        ).createShader(bounds);
      },
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white, // REQUIRED for ShaderMask
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
