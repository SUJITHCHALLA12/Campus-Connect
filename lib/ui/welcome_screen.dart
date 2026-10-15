import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/identity.dart';
import 'widgets/aurora_background.dart';

/// First-run screen: pick the display name nearby phones will see.
/// Deep abyss, bioluminescent glow, glass input.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    await context.read<IdentityStore>().setDisplayName(name);
    // HomeScreen takes over automatically via the identity watcher.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 2),
                  Center(
                    child: Container(
                      width: 132,
                      height: 132,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: CcColors.cyanGlow,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(32),
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    AppConstants.appName,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppConstants.appTagline,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      color: CcColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 48),
                  Text(
                    'What should nearby people call you?',
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      color: CcColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: CcGlass.input(radius: 18),
                    child: TextField(
                      controller: _controller,
                      maxLength: 24,
                      textCapitalization: TextCapitalization.words,
                      style: GoogleFonts.dmSans(
                          color: CcColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Your name',
                        hintStyle: GoogleFonts.dmSans(
                            color: CcColors.textMuted),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        counterText: '',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _saving ? null : _save,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(vertical: 17),
                      decoration:
                          CcGlass.buttonPrimary(radius: 18),
                      child: Center(
                        child: _saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Dive in',
                                style: GoogleFonts.nunito(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const Spacer(flex: 3),
                  Text(
                    'Works over Bluetooth with phones around you.\nNo account, no internet, no servers.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: CcColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
