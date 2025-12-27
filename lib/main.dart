/// Bimmerdash - BMW Enthusiast Dashboard
///
/// A comprehensive vehicle monitoring application for BMW enthusiasts.
/// Provides real-time vehicle data, diagnostics, and performance monitoring.
///
/// This is an independent enthusiast project and is not affiliated with,
/// sponsored by, or endorsed by BMW AG.
library;

import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'debug_logger.dart';
import 'debug_console.dart';

/// Constants for ENET Adapter Configuration
class EnetConstants {
  static const String defaultIp = "192.168.16.254";
  static const int defaultPort = 13400;
  static const int connectionTimeoutMs = 3000;

  // DoIP Routing Activation Request Packet
  static const List<int> routingActivationRequest = [
    0x02, 0xFD, 0x00, 0x01, 0x00, 0x00, 0x00, 0x07,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ];

  // Expected response prefix (DoIP Routing Activation Response)
  static const List<int> routingActivationResponsePrefix = [0x02, 0xFD, 0x80, 0x02];
}

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  MyApp({super.key});

  // Global key for ScaffoldMessenger to access from anywhere in the app
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bimmerdash',
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: BimmerdashColors.modernAccentOrange,
          secondary: BimmerdashColors.modernTextGray,
          surface: BimmerdashColors.modernDeepBlue,
          error: BimmerdashColors.redZone,
          onPrimary: BimmerdashColors.modernDeepBlue,
          onSecondary: BimmerdashColors.modernDeepBlue,
          onSurface: BimmerdashColors.modernTextGray,
          onError: BimmerdashColors.modernTextGray,
        ),
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: BimmerdashColors.modernDeepBlue,
      ),
      home: const SplashScreen(),
    );
  }
}

class VehicleInfo {
  final String vin;
  final int mileage;
  final String productionDate;
  final String modelSeries;
  final String manufacturer;
  final int modelYear;
  final int flashCycles;
  final int oilServiceMileage;
  final String oilServiceDate;

  VehicleInfo({
    this.vin = "",
    this.mileage = 0,
    this.productionDate = "",
    this.modelSeries = "Unbekannt",
    this.manufacturer = "BMW",
    this.modelYear = 0,
    this.flashCycles = 0,
    this.oilServiceMileage = 0,
    this.oilServiceDate = "",
  });

  String get shortVin => vin.length >= 7 ? vin.substring(vin.length - 7) : vin;

  factory VehicleInfo.fromJson(Map<String, dynamic> json) {
    return VehicleInfo(
      vin: json['vin'] ?? "",
      mileage: json['mileage'] ?? 0,
      productionDate: json['productionDate'] ?? "",
      modelSeries: json['modelSeries'] ?? "Unbekannt",
      manufacturer: json['manufacturer'] ?? "BMW",
      modelYear: json['modelYear'] ?? 0,
      flashCycles: json['flashCycles'] ?? 0,
      oilServiceMileage: json['oilServiceMileage'] ?? 0,
      oilServiceDate: json['oilServiceDate'] ?? "",
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'vin': vin,
      'mileage': mileage,
      'productionDate': productionDate,
      'modelSeries': modelSeries,
      'manufacturer': manufacturer,
      'modelYear': modelYear,
      'flashCycles': flashCycles,
      'oilServiceMileage': oilServiceMileage,
      'oilServiceDate': oilServiceDate,
    };
  }
}

class DashboardLayout {
  final GaugeConfig leftGauge;
  final GaugeConfig rightGauge;

  DashboardLayout({required this.leftGauge, required this.rightGauge});

  factory DashboardLayout.fromJson(Map<String, dynamic> json) {
    return DashboardLayout(
      leftGauge: GaugeConfig.fromJson(json['leftGauge'] ?? {}),
      rightGauge: GaugeConfig.fromJson(json['rightGauge'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'leftGauge': leftGauge.toJson(),
      'rightGauge': rightGauge.toJson(),
    };
  }
}

class GaugeConfig {
  final String mainParamId;
  final String? subParamId; // null means "None" - single gauge mode

  GaugeConfig({required this.mainParamId, this.subParamId});

  factory GaugeConfig.fromJson(Map<String, dynamic> json) {
    return GaugeConfig(
      mainParamId: json['mainParamId'] ?? 'boost',
      subParamId: json['subParamId'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mainParamId': mainParamId,
      'subParamId': subParamId,
    };
  }
}

class DisplayParam {
  final String id;
  final String label;
  final String unit;
  final String did;
  final double min;
  final double max;
  final Color color;
  final bool showRedZone;
  final DisplayParam? secondaryParam;

  DisplayParam({
    required this.id, required this.label, required this.unit,
    required this.did, required this.min, required this.max,
    required this.color, this.showRedZone = false, this.secondaryParam,
  });

  double decode(Uint8List data) {
    if (data.isEmpty) return 0.0;
    switch (id) {
      case 'oil_temp':
      case 'coolant':
      case 'iat':
      case 'gearbox_temp':
        return data[0].toDouble() - 40;
      case 'boost':
      case 'boost_alt':
        if (data.length < 2) return 0.0;
        int hpa = (data[0] << 8) | data[1];
        double bar = (hpa - 1013) / 1000.0;
        return bar < 0 ? 0.0 : bar;
      case 'throttle':
        return data[0].toDouble();
      default: return 0.0;
    }
  }

  static List<DisplayParam> available = [
    DisplayParam(id: 'none', label: "KEINE ANZEIGE", unit: "", did: "", min: 0, max: 0, color: Colors.grey),
    DisplayParam(id: 'oil_temp', label: "OIL TEMP", unit: "°C", did: "F45C", min: 60, max: 160, color: Colors.orange, showRedZone: true),
    DisplayParam(id: 'boost', label: "BOOST", unit: "BAR", did: "D906", min: 0, max: 2.0, color: Colors.blue, secondaryParam: DisplayParam(id: 'iat', label: "IAT", unit: "°C", did: "F40F", min: 0, max: 100, color: Colors.cyan)),
    DisplayParam(id: 'timing_all', label: "TIMING", unit: "°KW", did: "D011", min: -10, max: 0, color: Colors.red),
    DisplayParam(id: 'coolant', label: "WATER", unit: "°C", did: "F405", min: 60, max: 160, color: Colors.blueAccent, showRedZone: true),
    DisplayParam(id: 'iat', label: "INTAKE", unit: "°C", did: "F40F", min: 0, max: 100, color: Colors.cyan),
    DisplayParam(id: 'throttle', label: "THROTTLE", unit: "%", did: "F40E", min: 0, max: 100, color: Colors.green),
  ];
}

/// BMW-Inspired Color Scheme based on the app icon
class BimmerdashColors {
  static const Color deepNavyBlue = Color(0xFF000033); // Icon background
  static const Color bmwOrange = Color(0xFFFF8C00); // Icon accent/BMW orange
  static const Color silverGray = Color(0xFFB0B0C0); // Text and scales
  static const Color darkSurface = Color(0xFF1A1A2E); // Cards and surfaces
  static const Color darkGrayBlue = Color(0xFF12121A); // App bars and backgrounds
  static const Color redZone = Color(0xFFCE1237); // Warning/red zone color

  // Modern Performance Theme Colors
  static const Color modernDeepBlue = Color(0xFF001529); // Deep night blue
  static const Color modernAccentOrange = Color(0xFFFF8C00); // BMW Vivid Orange
  static const Color modernTextGray = Color(0xFFE0E0E0); // Aluminium Gray
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Simulate initialization (loading assets, checking network, etc.)
    await Future.delayed(const Duration(seconds: 3));

    // Check if we're connected to ENET_WIFI
    await _checkENETNetwork();

    // Navigate to main app
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const BimmerdashApp()),
      );
    }
  }

  Future<void> _checkENETNetwork() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.wifi) {
      // In a real app, we would check the specific SSID here
      // For now, we'll just try to ping the default ENET adapter IP
      try {
        // This would be replaced with actual ping functionality
        // For demo purposes, we'll just set a flag
        debugPrint("ENET network check completed");
      } catch (e) {
        debugPrint("ENET network check failed: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BimmerdashColors.modernDeepBlue,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Icon
            Image.asset(
              'assets/icon/app_icon_raw.png',
              width: 120,
              height: 120,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 30),

            // BIMMERDASH Text with Modern Typography
            Text(
              'BIMMERDASH',
              style: GoogleFonts.lexend(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: BimmerdashColors.modernTextGray,
                letterSpacing: 4.0,
                shadows: [
                  Shadow(
                    blurRadius: 2.0,
                    color: Colors.black.withValues(alpha: 0.3),
                    offset: Offset(1.0, 1.0),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Loading indicator with BMW Orange accent
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(
                  BimmerdashColors.modernAccentOrange,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BimmerdashApp extends StatelessWidget {
  const BimmerdashApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bimmerdash',
      theme: ThemeData(
        // Base dark theme with custom color scheme
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: BimmerdashColors.bmwOrange,
          secondary: BimmerdashColors.silverGray,
          surface: BimmerdashColors.deepNavyBlue,
          error: BimmerdashColors.redZone,
          onPrimary: BimmerdashColors.deepNavyBlue,
          onSecondary: BimmerdashColors.deepNavyBlue,
          onSurface: BimmerdashColors.silverGray,
          onError: BimmerdashColors.silverGray,
        ),

        // App bar theme
        appBarTheme: AppBarTheme(
          backgroundColor: BimmerdashColors.darkGrayBlue,
          foregroundColor: BimmerdashColors.silverGray,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
          ),
          iconTheme: IconThemeData(color: BimmerdashColors.silverGray),
        ),

        // Card theme
        cardTheme: CardThemeData(
          color: BimmerdashColors.darkSurface,
          surfaceTintColor: BimmerdashColors.bmwOrange.withValues(alpha: 0.1),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),

        // Button theme
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: BimmerdashColors.bmwOrange,
            foregroundColor: BimmerdashColors.deepNavyBlue,
            textStyle: TextStyle(
              fontWeight: FontWeight.bold,
              fontFamily: 'Roboto',
            ),
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),

        // Text button theme
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: BimmerdashColors.bmwOrange,
            textStyle: TextStyle(
              fontFamily: 'Roboto',
            ),
          ),
        ),

        // Dialog theme
        dialogTheme: DialogThemeData(
          backgroundColor: BimmerdashColors.darkSurface,
          titleTextStyle: TextStyle(
            color: BimmerdashColors.silverGray,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            fontFamily: 'Roboto',
          ),
          contentTextStyle: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
          ),
        ),

        // Switch theme
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return BimmerdashColors.bmwOrange;
            }
            return BimmerdashColors.silverGray;
          }),
          trackColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return BimmerdashColors.bmwOrange.withValues(alpha: 0.5);
            }
            return Colors.grey[800]!;
          }),
        ),

        // Slider theme
        sliderTheme: SliderThemeData(
          activeTrackColor: BimmerdashColors.bmwOrange,
          inactiveTrackColor: Colors.grey[800],
          thumbColor: BimmerdashColors.bmwOrange,
          overlayColor: BimmerdashColors.bmwOrange.withValues(alpha: 0.2),
          valueIndicatorColor: BimmerdashColors.deepNavyBlue,
        ),

        // Progress indicator theme
        progressIndicatorTheme: ProgressIndicatorThemeData(
          color: BimmerdashColors.bmwOrange,
          linearTrackColor: Colors.grey[800],
          circularTrackColor: Colors.grey[800],
        ),

        // Input decoration theme
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey[700]!),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey[700]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: BimmerdashColors.bmwOrange, width: 2),
          ),
          labelStyle: TextStyle(color: BimmerdashColors.silverGray),
          hintStyle: TextStyle(color: Colors.grey[600]),
        ),

        // Typography
        textTheme: TextTheme(
          displayLarge: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          displayMedium: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          displaySmall: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          headlineLarge: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          headlineMedium: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          headlineSmall: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          titleLarge: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          titleMedium: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          titleSmall: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          bodyLarge: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
          ),
          bodyMedium: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
          ),
          bodySmall: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
          ),
          labelLarge: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          labelMedium: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          labelSmall: TextStyle(
            color: BimmerdashColors.silverGray,
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
        ),

        // Scaffold background
        scaffoldBackgroundColor: BimmerdashColors.deepNavyBlue,

        // Use Roboto font family throughout
        fontFamily: 'Roboto',

        // Divider theme
        dividerTheme: DividerThemeData(
          color: Colors.grey[800],
          thickness: 1,
          space: 1,
        ),

        // Bottom navigation bar theme
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: BimmerdashColors.darkGrayBlue,
          selectedItemColor: BimmerdashColors.bmwOrange,
          unselectedItemColor: BimmerdashColors.silverGray,
          selectedLabelStyle: TextStyle(fontFamily: 'Roboto'),
          unselectedLabelStyle: TextStyle(fontFamily: 'Roboto'),
        ),

        // Tab bar theme
        tabBarTheme: TabBarThemeData(
          labelColor: BimmerdashColors.bmwOrange,
          unselectedLabelColor: BimmerdashColors.silverGray,
          indicator: UnderlineTabIndicator(
            borderSide: BorderSide(color: BimmerdashColors.bmwOrange, width: 2),
          ),
          labelStyle: TextStyle(
            fontFamily: 'Roboto',
            fontWeight: FontWeight.bold,
          ),
          unselectedLabelStyle: TextStyle(
            fontFamily: 'Roboto',
          ),
        ),
      ),
      home: const MonitorDashboard(),
    );
  }
}

class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({super.key});
  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  VehicleInfo vehicleInfo = VehicleInfo();
  double gaugeValueLeft = 0.0;
  double gaugeValueRight = 0.0;
  double peakLeft = 0.0;
  double peakRight = 0.0;
  double secondaryValueLeft = 0.0;
  double secondaryValueRight = 0.0;
  List<double> cylinderCorrections = List.filled(6, 0.0);
  double worstTimingCorrection = 0.0;
  int worstCylinder = 0;

  // Battery saving and polling optimization
  int _tickCounter = 0;
  bool isBatterySaveMode = false;
  int _zeroRpmCounter = 0;
  double lastRpmValue = 0.0;

  // Data categorization
  static const List<String> thermalDids = ['F45C', 'F405', 'F40F', 'F460']; // Thermal class (slow)
  static const String rpmDid = 'F40C'; // RPM for battery saving detection

  // Gauge configuration with preset management
  DashboardLayout currentLayout = DashboardLayout(
    leftGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat'),
    rightGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: null)
  );

  // Preset management
  Map<String, DashboardLayout> presets = {
    'Performance': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat'),
      rightGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: 'coolant')
    ),
    'Track': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'oil_temp', subParamId: 'coolant'),
      rightGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat')
    ),
    'Tuner': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: 'throttle'),
      rightGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat')
    ),
    'User 1': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat'),
      rightGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: null)
    ),
    'User 2': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat'),
      rightGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: null)
    ),
    'User 3': DashboardLayout(
      leftGauge: GaugeConfig(mainParamId: 'boost', subParamId: 'iat'),
      rightGauge: GaugeConfig(mainParamId: 'timing_all', subParamId: null)
    ),
  };

  // Derived parameters from config
  DisplayParam get leftParam => DisplayParam.available.firstWhere((p) => p.id == currentLayout.leftGauge.mainParamId, orElse: () => DisplayParam.available[0]);
  DisplayParam get rightParam => DisplayParam.available.firstWhere((p) => p.id == currentLayout.rightGauge.mainParamId, orElse: () => DisplayParam.available[2]);
  DisplayParam? get leftSecondaryParam => currentLayout.leftGauge.subParamId != null ? DisplayParam.available.firstWhere((p) => p.id == currentLayout.leftGauge.subParamId) : null;
  DisplayParam? get rightSecondaryParam => currentLayout.rightGauge.subParamId != null ? DisplayParam.available.firstWhere((p) => p.id == currentLayout.rightGauge.subParamId) : null;

  bool isConnected = false;
  bool isDiscovering = false;
  String statusText = "DISCONNECTED";
  Socket? _socket;
  Timer? _pollingTimer;
  String adapterIp = "192.168.16.254"; // ENET adapter default IP
  int doipPort = 13400; // DoIP standard port

  // Vehicle recognition state
  String carModel = "BMW PERFORMANCE";
  String vinDisplay = "";
  int cylinderCount = 6;
  Map<String, String> _modelDb = {};

  // DTC (Diagnostic Trouble Codes) state
  List<String> dtcCodes = [];
  Map<String, String> _dtcCodeDescriptions = {};
  bool isReadingDTCs = false;
  bool isClearingDTCs = false;

  // Connection test state
  bool isTestingConnection = false;
  bool? connectionTestResult;
  String connectionTestMessage = "";
  DateTime? lastConnectionTestTime;

  // Keep-Alive state
  Timer? _keepAliveTimer;
  int _keepAliveFailCount = 0;
  bool _autoReconnectAttempting = false;
  static const int maxKeepAliveFails = 3;
  static const int keepAliveIntervalSeconds = 2;
  static const int autoReconnectDelaySeconds = 5;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // --- SETTINGS STORAGE ---
  Future<File> _getSettingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, 'settings_v3.json'));
  }

  Future<void> _loadSettings() async {
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        setState(() {
          adapterIp = json['ip'] ?? "192.168.16.103";
          doipPort = json['port'] ?? 13400;
          
          if (json['vehicle_info'] != null) {
            vehicleInfo = VehicleInfo.fromJson(json['vehicle_info']);
            carModel = vehicleInfo.modelSeries;
            vinDisplay = vehicleInfo.vin;
          }

          // Load current layout with backward compatibility
          currentLayout = DashboardLayout(
            leftGauge: GaugeConfig(
              mainParamId: json['left_id'] ?? 'boost',
              subParamId: json['left_sub_id'],
            ),
            rightGauge: GaugeConfig(
              mainParamId: json['right_id'] ?? 'timing_all',
              subParamId: json['right_sub_id'],
            ),
          );
          // Load user presets if they exist
          if (json['user_presets'] != null) {
            final userPresetsJson = json['user_presets'] as Map<String, dynamic>;
            userPresetsJson.forEach((key, value) {
              if (presets.containsKey(key)) {
                presets[key] = DashboardLayout.fromJson(value);
              }
            });
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    final file = await _getSettingsFile();
    // Save user presets (User 1, User 2, User 3)
    final userPresets = {
      'User 1': presets['User 1']!.toJson(),
      'User 2': presets['User 2']!.toJson(),
      'User 3': presets['User 3']!.toJson(),
    };

    await file.writeAsString(jsonEncode({
      'ip': adapterIp,
      'port': doipPort,
      'left_id': currentLayout.leftGauge.mainParamId,
      'left_sub_id': currentLayout.leftGauge.subParamId,
      'right_id': currentLayout.rightGauge.mainParamId,
      'right_sub_id': currentLayout.rightGauge.subParamId,
      'user_presets': userPresets,
      'vehicle_info': vehicleInfo.toJson(),
    }));
  }


  // --- VEHICLE RECOGNITION ---
  Future<void> _loadVehicleModels() async {
    try {
      final jsonString = await rootBundle.loadString('assets/models.json');
      final jsonData = jsonDecode(jsonString);
      setState(() {
        _modelDb = Map<String, String>.from(jsonData);
      });
    } catch (e) {
      // Fallback to empty map if loading fails
      _modelDb = {};
    }
  }

  Future<void> _requestVehicleIdentification() async {
    if (_socket == null) return;
    _requestUdsData(0x22, 0xF190); // VIN
    _requestUdsData(0x22, 0xF18B); // Production Date
    _requestUdsData(0x22, 0xDE83); // Mileage
    _requestUdsData(0x22, 0xF100); // DME Flash Cycles
    _requestUdsData(0x22, 0xDE1F); // Oil Service Status
  }

  void _requestUdsData(int serviceId, int dataId) {
    if (_socket == null) return;
    int b1 = (dataId >> 8) & 0xFF;
    int b2 = dataId & 0xFF;
    _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x10, 0xF1, 0x03, serviceId, b1, b2]));
  }

  void _processVinResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;

    // Extract VIN from response (ASCII bytes)
    Uint8List vinBytes = data.sublist(16);
    String vin = String.fromCharCodes(vinBytes).trim();
    if (vin.length > 17) vin = vin.substring(0, 17);

    // Decode VIN Manufacturer
    String manufacturer = "Unknown";
    if (vin.startsWith("WBA") || vin.startsWith("WBS") || vin.startsWith("WBY")) {
      manufacturer = "BMW";
    } else if (vin.startsWith("WMW")) {
      manufacturer = "MINI";
    }

    // Decode Model Series using first 7 characters
    String modelSeries = "BMW (Unbekanntes Modell)";
    if (vin.length >= 7) {
      String modelCode = vin.substring(0, 7);
      // Try to find a match in our simplified map
      // WBA3R -> BMW 3er, etc.
      if (modelCode.startsWith("WBA3") || modelCode.startsWith("WBS3")) {
        modelSeries = "BMW 3er";
      } else if (modelCode.startsWith("WBA1") || modelCode.startsWith("WBS1")) {
        modelSeries = "BMW 1er";
      } else if (modelCode.startsWith("WBA5") || modelCode.startsWith("WBS5")) {
        modelSeries = "BMW 5er";
      } else if (modelCode.startsWith("WBAF")) {
        modelSeries = "BMW F-Serie";
      }
      
      // Also check against assets/models.json if loaded
      String innerCode = vin.substring(3, 7);
      if (_modelDb.containsKey(innerCode)) {
        modelSeries = _modelDb[innerCode]!;
      }
    }

    // Model Year (10th character)
    int year = 0;
    if (vin.length >= 10) {
      String yearChar = vin[9];
      const years = "ABCDEFGHJKLMNPRSTVWXY123456789";
      int idx = years.indexOf(yearChar);
      if (idx != -1) {
        // Simple mapping for modern cars (approximate)
        if (idx < 10) { // A-J: 2010-2018 approx
           year = 2010 + idx;
        } else if (idx < 20) { // K-Y: 2019-2030 approx
           year = 2010 + idx;
        } else { // 1-9: 2001-2009
           year = 2000 + (idx - 20) + 1;
        }
      }
    }

    if (mounted) {
      setState(() {
        vinDisplay = vin;
        carModel = modelSeries;
        vehicleInfo = VehicleInfo(
          vin: vin,
          mileage: vehicleInfo.mileage,
          productionDate: vehicleInfo.productionDate,
          modelSeries: modelSeries,
          manufacturer: manufacturer,
          modelYear: year,
        );
        
        // Update cylinder count based on model series
        int cylinders = 6;
        if (modelSeries.contains(RegExp(r'(120|125|320|330|420|430|MINI)', caseSensitive: false))) {
          cylinders = 4;
        }
        cylinderCount = cylinders;
        cylinderCorrections = List.filled(cylinders, 0.0);
      });
      _saveSettings();
    }
  }

  void _processMileageResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;
    Uint8List pld = data.sublist(16);
    if (pld.length >= 3) {
      // Decode 3-byte mileage (km)
      int mileage = (pld[0] << 16) | (pld[1] << 8) | pld[2];
      if (mounted) {
        setState(() {
          vehicleInfo = VehicleInfo(
            vin: vehicleInfo.vin,
            mileage: mileage,
            productionDate: vehicleInfo.productionDate,
            modelSeries: vehicleInfo.modelSeries,
            manufacturer: vehicleInfo.manufacturer,
            modelYear: vehicleInfo.modelYear,
          );
        });
        _saveSettings();
      }
    }
  }

  void _processProductionDateResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;
    Uint8List pld = data.sublist(16);
    // Usually DD.MM.YYYY or similar
    String date = String.fromCharCodes(pld).trim();
    if (mounted) {
      setState(() {
        vehicleInfo = VehicleInfo(
          vin: vehicleInfo.vin,
          mileage: vehicleInfo.mileage,
          productionDate: date,
          modelSeries: vehicleInfo.modelSeries,
          manufacturer: vehicleInfo.manufacturer,
          modelYear: vehicleInfo.modelYear,
          flashCycles: vehicleInfo.flashCycles,
          oilServiceMileage: vehicleInfo.oilServiceMileage,
          oilServiceDate: vehicleInfo.oilServiceDate,
        );
      });
      _saveSettings();
    }
  }

  void _processFlashCyclesResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;
    Uint8List pld = data.sublist(16);
    if (pld.length >= 2) {
      int cycles = (pld[0] << 8) | pld[1];
      if (mounted) {
        setState(() {
          vehicleInfo = VehicleInfo(
            vin: vehicleInfo.vin,
            mileage: vehicleInfo.mileage,
            productionDate: vehicleInfo.productionDate,
            modelSeries: vehicleInfo.modelSeries,
            manufacturer: vehicleInfo.manufacturer,
            modelYear: vehicleInfo.modelYear,
            flashCycles: cycles,
            oilServiceMileage: vehicleInfo.oilServiceMileage,
            oilServiceDate: vehicleInfo.oilServiceDate,
          );
        });
        _saveSettings();
      }
    }
  }

  void _processOilServiceResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;
    Uint8List pld = data.sublist(16);
    // BMW CBS Oil Service data mapping (example format)
    // Byte 0-1: Remaining Mileage (x10 or x100 depending on model, usually km directly)
    // Byte 2: Monthly index or date
    // This logic might need adjustment based on specific chassis (E/F/G)
    if (pld.length >= 4) {
      int restKm = (pld[0] << 8) | pld[1];
      // Date decoding: BMW often stores months since 2000 or similar
      // For simplicity, handle as MM.YYYY if possible, or use raw if not
      String dueDate = "${pld[2].toString().padLeft(2, '0')}.20${pld[3].toString().padLeft(2, '0')}";
      
      if (mounted) {
        setState(() {
          vehicleInfo = VehicleInfo(
            vin: vehicleInfo.vin,
            mileage: vehicleInfo.mileage,
            productionDate: vehicleInfo.productionDate,
            modelSeries: vehicleInfo.modelSeries,
            manufacturer: vehicleInfo.manufacturer,
            modelYear: vehicleInfo.modelYear,
            flashCycles: vehicleInfo.flashCycles,
            oilServiceMileage: restKm,
            oilServiceDate: dueDate,
          );
        });
        _saveSettings();
      }
    }
  }

  // --- DTC (DIAGNOSTIC TROUBLE CODES) FUNCTIONS ---
  Future<void> _loadDtcCodes() async {
    try {
      final jsonString = await rootBundle.loadString('assets/dtc_codes.json');
      final jsonData = jsonDecode(jsonString);
      setState(() {
        _dtcCodeDescriptions = Map<String, String>.from(jsonData);
      });
    } catch (e) {
      // Fallback to empty map if loading fails
      _dtcCodeDescriptions = {};
    }
  }

  Future<void> _readDtcs() async {
    if (_socket == null || !isConnected) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Error"),
          content: const Text("Nicht verbunden. Bitte zuerst Verbindung herstellen."),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
        ),
      );
      return;
    }

    setState(() {
      isReadingDTCs = true;
      dtcCodes = [];
    });

    try {
      // Send DTC read request (Service 0x19)
      _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x04, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x19, 0x02, 0x0C]));

      // Wait a bit for response
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        setState(() {
          isReadingDTCs = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isReadingDTCs = false;
        });
      }
    }
  }

  Future<void> _clearDtcs() async {
    if (_socket == null || !isConnected) {
      return;
    }

    setState(() {
      isClearingDTCs = true;
    });

    try {
      // Send DTC clear request (Service 0x14)
      _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x04, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x14, 0xFF, 0xFF, 0xFF]));

      // Wait a bit for response
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        setState(() {
          isClearingDTCs = false;
          dtcCodes = []; // Clear the error codes list
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isClearingDTCs = false;
        });
      }
    }
  }

  void _processDtcsResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x59) return; // Service 0x59 is DTC response

    // Extract DTC codes (3 bytes each)
    Uint8List dtcData = data.sublist(16);
    List<String> codes = [];

    // Process DTC data in 3-byte chunks
    for (int i = 0; i < dtcData.length; i += 3) {
      if (i + 3 <= dtcData.length) {
        // Extract 3 bytes and format as 6-digit hex code
        String code = dtcData.sublist(i, i + 3).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        codes.add(code);
      }
    }

    if (mounted) {
      setState(() {
        dtcCodes = codes;
      });
    }
  }

  Future<void> _launchKIAnalysis(String dtcCode) async {
    final url = 'https://www.google.com/search?q=BMW+DTC+CODE+$dtcCode+possible+causes+Gemini+analysis';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    }
  }

  // --- KEEP-ALIVE MECHANISM ---
  /// Starts the keep-alive timer to prevent connection timeout
  void _startKeepAlive() {
    _keepAliveTimer?.cancel(); // Cancel any existing timer
    _keepAliveFailCount = 0;

    _keepAliveTimer = Timer.periodic(
      const Duration(seconds: keepAliveIntervalSeconds),
      (timer) async {
        if (_socket == null || !isConnected) {
          timer.cancel();
          return;
        }

        try {
          // Send DoIP Keep-Alive request (empty DoIP header)
          final keepAliveRequest = Uint8List.fromList([0x02, 0xFD, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00]);
          _socket!.add(keepAliveRequest);
          debugPrint("Keep-Alive request sent");

          // Reset fail counter on successful send
          _keepAliveFailCount = 0;
        } catch (e) {
          debugPrint("Keep-Alive failed: $e");
          _keepAliveFailCount++;

          if (_keepAliveFailCount >= maxKeepAliveFails) {
            debugPrint("Max keep-alive failures reached, disconnecting...");
            _disconnect();
            _attemptAutoReconnect();
          }
        }
      },
    );
    debugPrint("Keep-Alive timer started (${keepAliveIntervalSeconds}s interval)");
  }

  /// Attempts to automatically reconnect to the ENET adapter
  void _attemptAutoReconnect() {
    if (_autoReconnectAttempting) return;

    _autoReconnectAttempting = true;
    setState(() {
      statusText = "RECONNECTING...";
    });

    Future.delayed(const Duration(seconds: autoReconnectDelaySeconds), () async {
      try {
        debugPrint("Attempting auto-reconnect to $adapterIp:$doipPort");
        await _connect();
      } catch (e) {
        debugPrint("Auto-reconnect failed: $e");
        if (mounted) {
          setState(() {
            statusText = "DISCONNECTED";
          });
        }
      } finally {
        _autoReconnectAttempting = false;
      }
    });
  }

  // --- CONNECTION TEST ---
  /// Performs a robust connection test to the ENET adapter
  /// Returns true if successful, false otherwise
  Future<bool> _performConnectionTest() async {
    final logger = DebugLogger();
    
    // Initial logging - Ensure the logger is properly initialized
    logger.log("Log-System bereit...", LogType.INFO); 
    logger.log("START: Verbindungstest eingeleitet...", LogType.INFO);

    // Network Interface Dump - Show all active interfaces
    try {
      logger.log("Netzwerk-Interface-Dump:", LogType.INFO);
      final networkInterfaces = await NetworkInterface.list();
      
      for (var interface in networkInterfaces) {
        final addresses = interface.addresses
            .map((addr) => "${addr.address}${addr.type == InternetAddressType.IPv4 ? '' : ' (IPv6)'}")
            .join(', ');
        logger.log("Aktives Interface: [Name: ${interface.name}, IP: $addresses]", LogType.data);
      }
      
      final localIp = networkInterfaces
          .expand((interface) => interface.addresses)
          .firstWhere(
            (addr) => addr.type == InternetAddressType.IPv4 && !addr.address.startsWith('127.'),
            orElse: () => InternetAddress('0.0.0.0'),
          )
          .address;

      logger.log("Hauptadresse für Verbindung: $localIp", LogType.INFO);
    } catch (e) {
      logger.log("Fehler beim Auflisten der Netzwerk-Interfaces: $e", LogType.ERROR);
    }

    // Check if WLAN is enabled
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      logger.log("WLAN Status: ${connectivityResult == ConnectivityResult.wifi ? 'Aktiv' : 'Inaktiv'}", 
        connectivityResult == ConnectivityResult.wifi ? LogType.SUCCESS : LogType.ERROR);
      
      if (connectivityResult != ConnectivityResult.wifi) {
        logger.log("ACHTUNG: WLAN ist nicht aktiv! Verbindung nicht möglich.", LogType.ERROR);
        return false;
      }
    } catch (e) {
      logger.log("Fehler bei WLAN-Status-Check: $e", LogType.ERROR);
    }

    // Stufe 1: ICMP Ping Test
    logger.log("Stufe 1: ICMP Ping-Test zu $adapterIp...", LogType.INFO);
    bool pingSuccessful = false;
    try {      
      final pingResult = await Process.run('ping', ['-c', '1', '-W', '2', adapterIp]);
      final exitCode = pingResult.exitCode;
      
      if (exitCode == 0) {
        logger.log("Ping-Check: Erreichbar (exitCode: $exitCode)", LogType.SUCCESS);
        pingSuccessful = true;
      } else {
        logger.log("Ping-Check: Nicht erreichbar (exitCode: $exitCode)", LogType.ERROR);
        logger.log("HINWEIS: Hardware physikalisch nicht im Netzwerk gefunden.", LogType.ERROR);
        logger.log("${pingResult.stdout}", LogType.data);
      }
    } catch (e) {
      logger.log("Ping-Fehler: $e", LogType.ERROR);
    }
    
    // Log that we're moving to the next step
    logger.log("Stufe 2: TCP Socket-Verbindungstest (${pingSuccessful ? 'nach erfolgreicher Ping' : 'trotz fehlgeschlagenem Ping'})...", LogType.INFO);

    // Stufe 2: Socket connection test
    bool socketConnected = false;
    Socket? socket;
    
    try {
      logger.log("Versuche TCP-Connect zu $adapterIp:$doipPort...", LogType.INFO);
      socket = await Socket.connect(
        adapterIp, 
        doipPort, 
        timeout: const Duration(seconds: 3)
      );
      logger.log("SUCCESS: Socket-Ebene verbunden!", LogType.SUCCESS);
      socketConnected = true;
    } on SocketException catch (e) {
      logger.log("ERROR (Socket): ${e.message}", LogType.ERROR);
      if (e.osError != null) {
        logger.log("Fehlercode: ${e.osError!.errorCode} - ${e.osError!.message}", LogType.ERROR);
      }
      logger.log("HINWEIS: Ist das Handy im ENET_WIFI?", LogType.INFO);
      return false;
    } on TimeoutException {
      logger.log("ERROR: Zeitüberschreitung nach 3 Sekunden. Adapter antwortet nicht.", LogType.ERROR);
      return false;
    } catch (e) {
      logger.log("UNBEKANNTER FEHLER: $e", LogType.ERROR);
      return false;
    }
    
    logger.log("Stufe 3: DoIP Routing Activation Test...", LogType.INFO);

    // Only continue if socket is connected
    if (socketConnected) {
      logger.log("Sende Routing Activation (Hex: ${EnetConstants.routingActivationRequest.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')})", LogType.data);

      // Send DoIP Routing Activation Request
      socket.add(Uint8List.fromList(EnetConstants.routingActivationRequest));

      logger.log("Warte auf Antwort vom ZGW...", LogType.INFO);

      // Wait for response with timeout
      final completer = Completer<bool>();
      final timer = Timer(const Duration(milliseconds: 2000), () {
        if (!completer.isCompleted) {
          socket?.destroy();
          logger.log("Timeout - Adapter antwortet nicht auf Port $doipPort", LogType.ERROR);
          completer.complete(false);
        }
      });

      socket.listen(
        (data) {
          if (!completer.isCompleted) {
            timer.cancel();

            logger.log("Empfangene Hex-Daten: ${data.sublist(0, math.min(20, data.length)).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}", LogType.data);

            // Check if response starts with expected DoIP routing activation response prefix
            if (data.length >= EnetConstants.routingActivationResponsePrefix.length) {
              bool isValidResponse = true;
              for (int i = 0; i < EnetConstants.routingActivationResponsePrefix.length; i++) {
                if (data[i] != EnetConstants.routingActivationResponsePrefix[i]) {
                  isValidResponse = false;
                  break;
                }
              }

              if (isValidResponse) {
                logger.log("DoIP-Aktivierung erfolgreich - Verbindung hergestellt", LogType.SUCCESS);
                logger.log("ALLE TESTS BESTANDEN - System ist bereit", LogType.SUCCESS);
                socket?.destroy();
                completer.complete(true);
              } else {
                logger.log("Ungültige Antwort erhalten - DoIP-Protokollfehler", LogType.ERROR);
                socket?.destroy();
                completer.complete(false);
              }
            } else {
              logger.log("Antwort zu kurz - ungültiges Datenformat", LogType.ERROR);
              socket?.destroy();
              completer.complete(false);
            }
          }
        },
        onError: (error) {
          if (!completer.isCompleted) {
            timer.cancel();
            socket?.destroy();

            // Error classification
            if (error is SocketException) {
              if (error.osError != null) {
                final errorCode = error.osError!.errorCode;
                if (errorCode == 113 || errorCode == 111) {
                  logger.log("Host nicht erreichbar. Prüfe WLAN/Statische IP.", LogType.ERROR);
                } else {
                  logger.log("Socket-Fehler: ${error.message} (Code: $errorCode)", LogType.ERROR);
                }
              } else {
                logger.log("Socket-Fehler: ${error.message}", LogType.ERROR);
              }
            } else {
              logger.log("Verbindungsfehler: ${error.toString()}", LogType.ERROR);
            }

            completer.complete(false);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            timer.cancel();
            logger.log("Socket geschlossen ohne gültige Antwort", LogType.ERROR);
            completer.complete(false);
          }
        },
      );

      return await completer.future;
    }
  }

  // --- NETWORK ---
  Future<void> _connect() async {
    try {
      setState(() => statusText = "CONNECTING...");
      _socket = await Socket.connect(adapterIp, doipPort, timeout: const Duration(seconds: 3));
      _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x00, 0x05, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]));
      _socket!.listen(_onDataReceived, onDone: _disconnect, onError: (_) => _disconnect());
      setState(() { isConnected = true; statusText = "CONNECTED"; });

      // Load vehicle models and request identification data once
      await _loadVehicleModels();
      await _requestVehicleIdentification();

      // Reset counters
      _tickCounter = 0;
      _zeroRpmCounter = 0;
      isBatterySaveMode = false;

      // Start Keep-Alive mechanism to prevent connection timeout
      _startKeepAlive();

      // Optimized polling with fast/slow categorization and battery saving
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (_socket == null) return;
        _tickCounter++;

        // Battery-Saving Check: If in battery save mode, only poll every 5 seconds (50 ticks)
        if (isBatterySaveMode && _tickCounter % 50 != 0) {
          return;
        }

        // Fast data (real-time) - every tick (100ms)
        // Left gauge fast data
        if (!thermalDids.contains(leftParam.did)) {
          _sendRequest(leftParam.did);
        }
        if (leftSecondaryParam != null && !thermalDids.contains(leftSecondaryParam!.did)) {
          _sendRequest(leftSecondaryParam!.did);
        }

        // Right gauge fast data
        if (!thermalDids.contains(rightParam.did)) {
          _sendRequest(rightParam.did);
        }
        if (rightSecondaryParam != null && !thermalDids.contains(rightSecondaryParam!.did)) {
          _sendRequest(rightSecondaryParam!.did);
        }

        // Timing correction (round-robin, one cylinder per tick)
        _sendRequest("D0${11 + (_tickCounter % cylinderCount)}");

        // Thermal data (slow) - every 10 ticks (1 second)
        if (_tickCounter % 10 == 0) {
          // Left gauge thermal data
          if (thermalDids.contains(leftParam.did)) {
            _sendRequest(leftParam.did);
          }
          if (leftSecondaryParam != null && thermalDids.contains(leftSecondaryParam!.did)) {
            _sendRequest(leftSecondaryParam!.did);
          }

          // Right gauge thermal data
          if (thermalDids.contains(rightParam.did)) {
            _sendRequest(rightParam.did);
          }
          if (rightSecondaryParam != null && thermalDids.contains(rightSecondaryParam!.did)) {
            _sendRequest(rightSecondaryParam!.did);
          }

          // RPM for battery saving detection
          _sendRequest(rpmDid);
        }
      });
    } catch (e) { setState(() => statusText = "FAILED"); _disconnect(); }
  }

  void _sendRequest(String didStr) {
    if (didStr.isEmpty) return;
    int b1 = int.parse(didStr.substring(0, 2), radix: 16);
    int b2 = int.parse(didStr.substring(2, 4), radix: 16);
    _socket?.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x22, b1, b2]));
  }

  void _onDataReceived(Uint8List data) {
    if (data.length < 17) return;

    // Handle initial routing activation response if needed
    // ...

    // Handle UDS data response (Service 0x62)
    if (data[13] == 0x62) {
      String rDid = data[14].toRadixString(16).padLeft(2, '0').toUpperCase() + data[15].toRadixString(16).padLeft(2, '0').toUpperCase();
      Uint8List pld = data.sublist(16);

      // Handle Vehicle Info responses
      if (rDid == "F190") {
        _processVinResponse(data);
      } else if (rDid == "DE83") {
        _processMileageResponse(data);
      } else if (rDid == "F18B") {
        _processProductionDateResponse(data);
      } else if (rDid == "F100") {
        _processFlashCyclesResponse(data);
      } else if (rDid == "DE1F") {
        _processOilServiceResponse(data);
      }

      // Handle RPM response for battery saving detection
      if (rDid == rpmDid) {
        // RPM is stored as 2 bytes (little endian)
        if (pld.length >= 2) {
          int rpm = (pld[1] << 8) | pld[0];
          lastRpmValue = rpm.toDouble();

          // Battery saving logic: Check if engine is off (RPM = 0)
          if (rpm == 0) {
            _zeroRpmCounter++;
            // Enter battery save mode after 30 seconds of RPM = 0
            if (_zeroRpmCounter >= 300 && !isBatterySaveMode) {
              setState(() {
                isBatterySaveMode = true;
                statusText = "BATTERY SAVE MODE";
              });
            }
          } else {
            // Engine is running, reset counter and exit battery save mode
            _zeroRpmCounter = 0;
            if (isBatterySaveMode) {
              setState(() {
                isBatterySaveMode = false;
                statusText = "CONNECTED";
              });
            }
          }
        }
      }

      setState(() {
        if (rDid == leftParam.did) { gaugeValueLeft = leftParam.decode(pld); if (gaugeValueLeft > peakLeft) peakLeft = gaugeValueLeft; }
        else if (rDid == rightParam.did) { gaugeValueRight = rightParam.decode(pld); if (gaugeValueRight > peakRight) peakRight = gaugeValueRight; }
        else if (leftParam.secondaryParam != null && rDid == leftParam.secondaryParam!.did) {
          secondaryValueLeft = leftParam.secondaryParam!.decode(pld);
        }
        else if (rightParam.secondaryParam != null && rDid == rightParam.secondaryParam!.did) {
          secondaryValueRight = rightParam.secondaryParam!.decode(pld);
        }
        else if (rDid.startsWith("D01")) {
          int idx = int.parse(rDid.substring(3)) - 1;
          double cr = (pld[0] - 128) * 0.1;
          cylinderCorrections[idx] = cr;
          if (cr < worstTimingCorrection) { worstTimingCorrection = cr; worstCylinder = idx + 1; }
        }
      });
    } else if (data[13] == 0x59) {
      // DTC response (Service 0x59 - ReadDTCByStatusMask response 0x19 + 0x40)
      _processDtcsResponse(data);
    }
  }

  void _disconnect() {
    _pollingTimer?.cancel();
    _socket?.destroy();
    _socket = null;
    if (mounted) {
      setState(() {
        isConnected = false;
        statusText = "DISCONNECTED";
        vehicleInfo = VehicleInfo();
        carModel = "BMW Performance";
        vinDisplay = "";
        cylinderCount = 6;
        cylinderCorrections = List.filled(6, 0.0);
      });
    }
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
            maxWidth: MediaQuery.of(context).size.width * 0.95,
          ),
          child: DefaultTabController(
            length: 4,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Settings", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.speed), text: "Instruments"),
                    Tab(icon: Icon(Icons.balance), text: "Units"),
                    Tab(icon: Icon(Icons.settings_input_component), text: "System"),
                    Tab(icon: Icon(Icons.info), text: "About"),
                  ],
                  isScrollable: true,
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      // Instruments Tab
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Left Gauge", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 4),
                                          child: Text("Main Parameter:", style: TextStyle(fontWeight: FontWeight.bold)),
                                        ),
                                        DropdownButtonFormField<String>(
                                          initialValue: currentLayout.leftGauge.mainParamId,
                                          isExpanded: true,
                                          isDense: true,
                                          decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            ),
                                            items: DisplayParam.available.map((p) => 
                                              DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))
                                            ).toList(),
                                            onChanged: (id) => setState(() => currentLayout = DashboardLayout(
                                              leftGauge: GaugeConfig(mainParamId: id ?? 'boost', subParamId: currentLayout.leftGauge.subParamId),
                                              rightGauge: currentLayout.rightGauge
                                            )),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                                            child: Text("Sub Parameter:", style: TextStyle(fontWeight: FontWeight.bold)),
                                          ),
                                          DropdownButtonFormField<String?>(
                                            initialValue: currentLayout.leftGauge.subParamId,
                                            isExpanded: true,
                                            isDense: true,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            ),
                                            items: [
                                              const DropdownMenuItem(value: null, child: Text("NONE")),
                                              ...DisplayParam.available.where((p) => p.id != 'none').map((p) =>
                                                DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))
                                              )
                                            ],
                                            onChanged: (id) => setState(() => currentLayout = DashboardLayout(
                                              leftGauge: GaugeConfig(mainParamId: currentLayout.leftGauge.mainParamId, subParamId: id),
                                              rightGauge: currentLayout.rightGauge
                                            )),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Right Gauge", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 4),
                                            child: Text("Main Parameter:", style: TextStyle(fontWeight: FontWeight.bold)),
                                          ),
                                          DropdownButtonFormField<String>(
                                            initialValue: currentLayout.rightGauge.mainParamId,
                                            isExpanded: true,
                                            isDense: true,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            ),
                                            items: DisplayParam.available.map((p) =>
                                              DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))
                                            ).toList(),
                                            onChanged: (id) => setState(() => currentLayout = DashboardLayout(
                                              leftGauge: currentLayout.leftGauge,
                                              rightGauge: GaugeConfig(mainParamId: id ?? 'timing_all', subParamId: currentLayout.rightGauge.subParamId)
                                            )),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                                            child: Text("Sub Parameter:", style: TextStyle(fontWeight: FontWeight.bold)),
                                          ),
                                          DropdownButtonFormField<String?>(
                                            initialValue: currentLayout.rightGauge.subParamId,
                                            isExpanded: true,
                                            isDense: true,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                            ),
                                            items: [
                                              const DropdownMenuItem(value: null, child: Text("NONE")),
                                              ...DisplayParam.available.where((p) => p.id != 'none').map((p) =>
                                                DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))
                                              )
                                            ],
                                            onChanged: (id) => setState(() => currentLayout = DashboardLayout(
                                              leftGauge: currentLayout.leftGauge,
                                              rightGauge: GaugeConfig(mainParamId: currentLayout.rightGauge.mainParamId, subParamId: id)
                                            )),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Quick Load Presets", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          ElevatedButton(
                                            onPressed: () { setState(() { currentLayout = presets['Performance']!; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                                            child: const Text("Performance"),
                                          ),
                                          ElevatedButton(
                                            onPressed: () { setState(() { currentLayout = presets['Track']!; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                                            child: const Text("Track"),
                                          ),
                                          ElevatedButton(
                                            onPressed: () { setState(() { currentLayout = presets['Tuner']!; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
                                            child: const Text("Tuner"),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Save Current Configuration", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          ElevatedButton(
                                            onPressed: () { setState(() { presets['User 1'] = currentLayout; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                                            child: const Text("User 1"),
                                          ),
                                          ElevatedButton(
                                            onPressed: () { setState(() { presets['User 2'] = currentLayout; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                                            child: const Text("User 2"),
                                          ),
                                          ElevatedButton(
                                            onPressed: () { setState(() { presets['User 3'] = currentLayout; }); },
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                                            child: const Text("User 3"),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      ...['User 1', 'User 2', 'User 3'].map((userKey) => Card(
                                        child: ListTile(
                                          title: Text(userKey),
                                          subtitle: Text("${presets[userKey]!.leftGauge.mainParamId} + ${presets[userKey]!.leftGauge.subParamId ?? 'none'} | ${presets[userKey]!.rightGauge.mainParamId} + ${presets[userKey]!.rightGauge.subParamId ?? 'none'}"),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.play_arrow, color: Colors.green),
                                            tooltip: "Load $userKey",
                                            onPressed: () => setState(() => currentLayout = presets[userKey]!),
                                          ),
                                        ),
                                      )),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Units Tab
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Temperature Units", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      SwitchListTile(
                                        title: const Text("Use Fahrenheit"),
                                        subtitle: const Text("°C / °F"),
                                        value: false, // Placeholder - would need to add unit settings state
                                        onChanged: (bool value) {
                                          // Placeholder - would need to implement unit settings
                                        },
                                      ),
                                      const SizedBox(height: 16),
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Pressure Units", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      SwitchListTile(
                                        title: const Text("Use PSI"),
                                        subtitle: const Text("Bar / PSI"),
                                        value: false, // Placeholder
                                        onChanged: (bool value) {
                                          // Placeholder
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // System Tab
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              // Connection Test Card
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Connection Test", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      // Connection Test Button and Status Indicator
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: isTestingConnection ? null : () async {
                                                setState(() {
                                                  isTestingConnection = true;
                                                  connectionTestResult = null;
                                                  connectionTestMessage = "Test läuft...";
                                                });

                                                final testResult = await _performConnectionTest();
                                                final testTime = DateTime.now();

                                                if (!context.mounted) return;

                                                setState(() {
                                                  isTestingConnection = false;
                                                  connectionTestResult = testResult;
                                                  lastConnectionTestTime = testTime;
                                                  connectionTestMessage = testResult
                                                    ? "Verbindung erfolgreich"
                                                    : "Adapter nicht erreichbar. Zündung an?";
                                                });

                                                if (testResult) {
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('Success'),
                                                      content: const Text("Bimmerdash ist bereit. Steuergerät antwortet."),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(context),
                                                          child: const Text('OK'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                } else {
                                                  if (!context.mounted) return;
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('Error'),
                                                      content: const Text("Verbindungstest fehlgeschlagen."),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(context),
                                                          child: const Text('OK'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }

                                              },
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: isTestingConnection ? Colors.grey : Colors.blue,
                                              ),
                                              child: isTestingConnection
                                                ? const SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                                  )
                                                : const Text("Verbindung testen"),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          // Status Indicator LED
                                          Container(
                                            width: 16,
                                            height: 16,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: isTestingConnection
                                                ? Colors.yellow
                                                : connectionTestResult == null
                                                  ? Colors.grey
                                                  : connectionTestResult!
                                                    ? Colors.green
                                                    : Colors.red,
                                              boxShadow: isTestingConnection || connectionTestResult == true
                                                ? [
                                                    const BoxShadow(
                                                      color: Colors.green, // Fallback for withValues
                                                      blurRadius: 8,
                                                      spreadRadius: 2,
                                                    ),
                                                  ]
                                                : null,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      // Status Message and Timestamp
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              connectionTestMessage,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: connectionTestResult == null
                                                  ? Colors.grey
                                                  : connectionTestResult!
                                                    ? Colors.green
                                                    : Colors.red,
                                              ),
                                            ),
                                            if (lastConnectionTestTime != null)
                                              Text(
                                                "Letzter Test: ${lastConnectionTestTime!.hour.toString().padLeft(2, '0')}:${lastConnectionTestTime!.minute.toString().padLeft(2, '0')}",
                                                style: const TextStyle(fontSize: 10, color: Colors.grey),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Debug Console
                              Builder(
                                builder: (context) => DebugConsole(
                                  scaffoldContext: context,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Battery Saver", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 8),
                                      SwitchListTile(
                                        title: const Text("Enable Battery Save Mode"),
                                        subtitle: const Text("Reduces polling when engine is off"),
                                        value: isBatterySaveMode,
                                        onChanged: (bool value) {
                                          setState(() {
                                            isBatterySaveMode = value;
                                          });
                                        },
                                      ),
                                      const SizedBox(height: 16),
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Engine Configuration", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                      const SizedBox(height: 12),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          const Text("Cylinder Count:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                                          const SizedBox(height: 4),
                                          DropdownButtonFormField<int>(
                                            initialValue: cylinderCount,
                                            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                                            items: const [
                                              DropdownMenuItem(value: 4, child: Text("4-Zylinder")),
                                              DropdownMenuItem(value: 6, child: Text("6-Zylinder")),
                                            ],
                                            onChanged: (val) {
                                              if (val != null) {
                                                setState(() {
                                                  cylinderCount = val;
                                                  cylinderCorrections = List.filled(val, 0.0);
                                                });
                                                _saveSettings();
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // About Tab
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("About Bimmerdash", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                                      ),
                                      const SizedBox(height: 12),
                                      const ListTile(
                                        leading: Icon(Icons.info, color: Colors.blue),
                                        title: Text("App Name", style: TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text("Bimmerdash"),
                                      ),
                                      const ListTile(
                                        leading: Icon(Icons.numbers, color: Colors.blue),
                                        title: Text("Version", style: TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text("1.0.0"),
                                      ),
                                      ListTile(
                                        leading: const Icon(Icons.car_repair, color: Colors.blue),
                                        title: const Text("Vehicle Model", style: TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text(carModel),
                                      ),
                                      if (vinDisplay.isNotEmpty)
                                        ListTile(
                                          leading: const Icon(Icons.vpn_key, color: Colors.blue),
                                          title: const Text("VIN", style: TextStyle(fontWeight: FontWeight.bold)),
                                          subtitle: Text(vinDisplay),
                                        ),
                                      ListTile(
                                        leading: const Icon(Icons.cloud, color: Colors.blue),
                                        title: const Text("Connection Status", style: TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text(statusText),
                                        trailing: Icon(
                                          isConnected ? Icons.cloud_done : Icons.cloud_off,
                                          color: isConnected ? Colors.green : Colors.red,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      const Divider(),
                                      const SizedBox(height: 16),
                                      const Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text("Legal Information", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange)),
                                      ),
                                      const SizedBox(height: 8),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 4),
                                        child: Text(
                                          "Bimmerdash is an independent enthusiast project and is not affiliated with, sponsored by, or endorsed by BMW AG. BMW is a registered trademark of BMW AG. Any use of the brand name or terminology is for identification purposes only.",
                                          style: TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () { Navigator.pop(context); },
                        child: const Text("Cancel"),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: () { 
                          _saveSettings(); 
                          Navigator.pop(context); 
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                        child: const Text("Save & Apply"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDiagnosisDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("DIAGNOSE"),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: isReadingDTCs ? null : () async {
                  Navigator.pop(context);
                  await _loadDtcCodes();
                  await _readDtcs();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: isReadingDTCs
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("FEHLER AUSLESEN"),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: isClearingDTCs ? null : () async {
                  Navigator.pop(context);
                  await _clearDtcs();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: isClearingDTCs
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("FEHLERSPEICHER LÖSCHEN"),
              ),
              const SizedBox(height: 20),
              if (dtcCodes.isEmpty)
                const Text("Keine Fehlercodes gefunden", style: TextStyle(color: Colors.green))
              else
                Column(
                  children: dtcCodes.map((code) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: InkWell(
                      onTap: () => _launchKIAnalysis(code),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Text(code, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _dtcCodeDescriptions[code] ?? "Unbekannter Fehlercode",
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            const Icon(Icons.open_in_new, size: 16, color: Colors.blue),
                          ],
                        ),
                      ),
                    ),
                  )).toList(),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("SCHLIESSEN"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: BimmerdashColors.darkGrayBlue,
        title: Row(children: [
          // Compact connection status indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isConnected ? Colors.blue.withValues(alpha: 0.2) : Colors.red.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isConnected ? Icons.cloud_done : Icons.cloud_off,
                  size: 14,
                  color: isConnected ? Colors.blue : Colors.red,
                ),
                const SizedBox(width: 4),
                Text(
                  isConnected ? "ONLINE" : "OFFLINE",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isConnected ? Colors.blue : Colors.red,
                  ),
                ),
              ],
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.favorite),
            tooltip: "Vehicle Health",
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => VehicleHealthPage(
              info: vehicleInfo, 
              isConnected: isConnected,
              onUpdate: () => _requestVehicleIdentification(),
            ))),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
          IconButton(
            icon: const Icon(Icons.medical_services),
            onPressed: () => _showDiagnosisDialog(),
          ),
          IconButton(
            icon: Icon(isConnected ? Icons.stop : Icons.play_arrow),
              onPressed: isDiscovering ? null : (isConnected ? () => _disconnect() : () => _connect()),

            color: isConnected ? Colors.red : Colors.blue,
          ),
        ],
      ),
      body: Column(children: [
        _buildVehicleInfoBar(),
        _buildWorstCaseBar(),
        Expanded(child: Row(children: [
          Expanded(child: _buildTile(leftParam, gaugeValueLeft, peakLeft)),
          Expanded(child: _buildTile(rightParam, gaugeValueRight, peakRight)),
        ])),
      ]),
    );
  }

  Widget _buildVehicleInfoBar() {
    if (!isConnected) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      color: Colors.blue.withValues(alpha: 0.1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_car, size: 16, color: Colors.blue),
              const SizedBox(width: 8),
              Text(
                "${vehicleInfo.manufacturer} ${vehicleInfo.modelSeries}",
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              if (vehicleInfo.modelYear > 0)
                Text(" (${vehicleInfo.modelYear})", style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          Row(
            children: [
              Text(
                "VIN: ${vehicleInfo.shortVin}",
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.orange),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.straighten, size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                "${vehicleInfo.mileage} km",
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWorstCaseBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      color: Colors.white.withValues(alpha: 0.05),
      child: Row(children: [
        const Icon(Icons.history, size: 14, color: Colors.grey),
        const SizedBox(width: 5),
        Text("PEAK: ${worstTimingCorrection.toStringAsFixed(1)}° (Z$worstCylinder)", style: TextStyle(fontSize: 12, color: worstTimingCorrection < -3 ? Colors.red : Colors.grey)),
        const Spacer(),
        GestureDetector(onTap: () => setState(() { worstTimingCorrection = 0; worstCylinder = 0; }), child: const Text("RESET LOG", style: TextStyle(fontSize: 10, color: Colors.blue))),
      ]),
    );
  }

  Widget _buildTile(DisplayParam p, double val, double peak) {
    if (p.id == 'timing_all') return HorizontalTimingChart(corrections: cylinderCorrections, min: p.min, cylinderCount: cylinderCount);

    // Determine which gauge config this corresponds to
    GaugeConfig gaugeConfig;
    double? secondaryValue;
    if (p == leftParam) {
      gaugeConfig = currentLayout.leftGauge;
      secondaryValue = secondaryValueLeft;
    } else {
      gaugeConfig = currentLayout.rightGauge;
      secondaryValue = secondaryValueRight;
    }

    return MGauge(value: val, peakValue: peak, param: p, gaugeConfig: gaugeConfig, secondaryValue: secondaryValue);
  }
}

class HorizontalTimingChart extends StatelessWidget {
  final List<double> corrections;
  final double min;
  final int cylinderCount;
  const HorizontalTimingChart({super.key, required this.corrections, required this.min, this.cylinderCount = 6});
  @override
  Widget build(BuildContext context) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text("TIMING CORRECTION", style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
      const SizedBox(height: 15),
      ...List.generate(cylinderCount, (i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 15),
        child: Row(children: [
          Text("Z${i + 1}", style: const TextStyle(fontSize: 9)),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 10, decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(2)), child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: (corrections[i] / (min == 0 ? 1 : min)).clamp(0.0, 1.0), child: Container(decoration: BoxDecoration(color: corrections[i] < -3 ? Colors.red : Colors.orange, borderRadius: BorderRadius.circular(2)))))),
          const SizedBox(width: 10),
          Text(corrections[i].toStringAsFixed(1), style: const TextStyle(fontSize: 9)),
        ]),
      )),
    ]);
  }
}

class MGauge extends StatelessWidget {
  final double value, peakValue;
  final DisplayParam param;
  final GaugeConfig gaugeConfig;
  final double? secondaryValue;
  const MGauge({super.key, required this.value, required this.peakValue, required this.param, required this.gaugeConfig, this.secondaryValue});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      double size = math.min(constraints.maxWidth, constraints.maxHeight * 0.85);
      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(param.label, style: TextStyle(fontSize: size * 0.07, fontWeight: FontWeight.bold, color: Colors.grey[400])),
        SizedBox(height: size * 0.05),
        Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size(size, size), painter: GaugePainter(
            value: value,
            peakValue: peakValue,
            min: param.min,
            max: param.max,
            needleColor: param.color,
            showRedZone: param.showRedZone,
            gaugeConfig: gaugeConfig,
            secondaryValue: secondaryValue
          )),
          Positioned(
            bottom: gaugeConfig.subParamId != null ? size * 0.22 : size * 0.28,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(param.max > 5 ? value.toInt().toString() : value.toStringAsFixed(2), style: TextStyle(fontSize: size * 0.2, fontWeight: FontWeight.bold)),
                Text(param.unit, style: TextStyle(fontSize: size * 0.07, color: Colors.grey)),
                if (gaugeConfig.subParamId != null && secondaryValue != null) ...[
                  SizedBox(height: size * 0.03),
                  Text("${DisplayParam.available.firstWhere((p) => p.id == gaugeConfig.subParamId).label}: ${DisplayParam.available.firstWhere((p) => p.id == gaugeConfig.subParamId).max > 5 ? secondaryValue!.toInt().toString() : secondaryValue!.toStringAsFixed(1)}${DisplayParam.available.firstWhere((p) => p.id == gaugeConfig.subParamId).unit}",
                    style: TextStyle(fontSize: size * 0.06, color: Colors.grey[400])),
                ]
              ]
            )
          )
        ])
      ]);
    });
  }
}

class GaugePainter extends CustomPainter {
  final double value, peakValue, min, max;
  final Color needleColor;
  final bool showRedZone;
  final GaugeConfig gaugeConfig;
  final double? secondaryValue;
  GaugePainter({required this.value, required this.peakValue, required this.min, required this.max, required this.needleColor, required this.showRedZone, required this.gaugeConfig, this.secondaryValue});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final outerRect = Rect.fromCircle(center: center, radius: radius);

    // Background Gradient - Modern Performance Theme
    canvas.drawCircle(center, radius, Paint()..shader = RadialGradient(colors: [BimmerdashColors.modernDeepBlue, Colors.black], stops: const [0.7, 1.0]).createShader(outerRect));
    canvas.drawCircle(center, radius, Paint()..color = Colors.grey[800]!..style = PaintingStyle.stroke..strokeWidth = 2);

    // Ticks & Numbers
    for (int i = 0; i <= 50; i++) {
      final angle = (math.pi * 0.85) + (i / 50 * math.pi * 1.3);
      final isMajor = i % 5 == 0;
      final tickLength = isMajor ? radius * 0.12 : radius * 0.06;
      final startRadius = radius - 4;
      canvas.drawLine(
        Offset(center.dx + startRadius * math.cos(angle), center.dy + startRadius * math.sin(angle)),
        Offset(center.dx + (startRadius - tickLength) * math.cos(angle), center.dy + (startRadius - tickLength) * math.sin(angle)),
        Paint()..color = isMajor ? Colors.white.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.4)..strokeWidth = isMajor ? 2.5 : 1.2..strokeCap = StrokeCap.round,
      );

      if (isMajor && i % 10 == 0) {
        final val = min + (i / 50 * (max - min));
        if (max > 100 && (val < 60 || val > 160)) continue;
        final textRadius = startRadius - tickLength - 15;
        final textPainter = TextPainter(text: TextSpan(text: max > 5 ? val.toInt().toString() : val.toStringAsFixed(1), style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: radius * 0.12, fontWeight: FontWeight.w400)), textDirection: TextDirection.ltr);
        textPainter.layout();
        textPainter.paint(canvas, Offset(center.dx + textRadius * math.cos(angle) - textPainter.width / 2, center.dy + textRadius * math.sin(angle) - textPainter.height / 2));
      }
    }

    // Red Zone
    if (showRedZone && max > 100) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 8), (math.pi * 0.85) + ((120 - min) / (max - min) * math.pi * 1.3), ((max - 120) / (max - min) * math.pi * 1.3), false, Paint()..color = const Color(0xFFCE1237).withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = 3);
    }

    // Outer Glow Effect - Modern Performance Theme
    final normalizedValue = ((value - min) / (max - min)).clamp(0.0, 1.0);
    if (normalizedValue > 0.5) { // Glow effect when value is above 50%
      final glowIntensity = (normalizedValue - 0.5) * 2.0; // 0.0 to 1.0 intensity
      final outerGlowPaint = Paint()
        ..color = BimmerdashColors.modernAccentOrange.withValues(alpha: 0.1 * glowIntensity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 15 * glowIntensity
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * glowIntensity);

      canvas.drawCircle(center, radius * 0.95, outerGlowPaint);
    }

    // Needle Shadow & Needle with Glow Effect (BMW Orange)
    final angle = (math.pi * 0.85) + (((value - min) / (max - min)).clamp(0.0, 1.0) * math.pi * 1.3);

    // Glow effect for main needle (BMW Orange)
    final glowPaint = Paint()
      ..color = BimmerdashColors.bmwOrange.withValues(alpha: 0.8)
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawLine(center, Offset(center.dx + (radius * 0.82) * math.cos(angle), center.dy + (radius * 0.82) * math.sin(angle)), glowPaint);

    // Main needle with proper color
    canvas.drawLine(center, Offset(center.dx + (radius * 0.82) * math.cos(angle), center.dy + (radius * 0.82) * math.sin(angle)), Paint()..color = needleColor..strokeWidth = 3.5..strokeCap = StrokeCap.round);

    // Secondary Scale
    if (gaugeConfig.subParamId != null && secondaryValue != null) {
      final secondaryParam = DisplayParam.available.firstWhere((p) => p.id == gaugeConfig.subParamId);
      final secondaryArcRadius = radius * 0.65;
      final sweepAngle = math.pi * 0.4;
      final startAngle = 0.5 * math.pi - (sweepAngle / 2);
      final secondaryValueNormalized = ((secondaryValue! - secondaryParam.min) / (secondaryParam.max - secondaryParam.min)).clamp(0.0, 1.0);

      final tickPaint = Paint()..color = Colors.white24..strokeWidth = 1.5..strokeCap = StrokeCap.round;
      for (int i = 0; i <= 4; i++) {
        final tickAngle = startAngle + (i / 4 * sweepAngle);
        final tickStartRadius = secondaryArcRadius - (radius * 0.02);
        final tickEndRadius = secondaryArcRadius + (radius * 0.02);
        canvas.drawLine(Offset(center.dx + tickStartRadius * math.cos(tickAngle), center.dy + tickStartRadius * math.sin(tickAngle)), Offset(center.dx + tickEndRadius * math.cos(tickAngle), center.dy + tickEndRadius * math.sin(tickAngle)), tickPaint);
      }

      final trackPaint = Paint()..color = Colors.grey[800]!.withValues(alpha: 0.8)..style = PaintingStyle.stroke..strokeWidth = radius * 0.06..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCircle(center: center, radius: secondaryArcRadius), startAngle, sweepAngle, false, trackPaint);

      final progressPaint = Paint()..color = const Color(0xFF0066B1)..style = PaintingStyle.stroke..strokeWidth = radius * 0.06..strokeCap = StrokeCap.round..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawArc(Rect.fromCircle(center: center, radius: secondaryArcRadius), startAngle, secondaryValueNormalized * sweepAngle, false, progressPaint);
    }

    // Center Hub
    canvas.drawCircle(center, radius * 0.1, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(center, radius * 0.08, Paint()..color = const Color(0xFF333333));
  }
  @override bool shouldRepaint(covariant GaugePainter old) => true;
}

/// A dedicated page for vehicle identification and health summary.
class VehicleHealthPage extends StatelessWidget {
  final VehicleInfo info;
  final bool isConnected;
  final VoidCallback onUpdate;

  const VehicleHealthPage({
    super.key,
    required this.info,
    required this.isConnected,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BimmerdashColors.modernDeepBlue,
      appBar: AppBar(
        title: const Text("VEHICLE HEALTH"),
        backgroundColor: BimmerdashColors.darkGrayBlue,
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: "Daten aktualisieren",
              onPressed: onUpdate,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header Card (Profile)
            _buildHeaderCard(),
            const SizedBox(height: 20),
            // Diagnostic Grid
            _buildDataGrid(),
            const SizedBox(height: 30),
            if (isConnected)
              ElevatedButton.icon(
                onPressed: onUpdate,
                icon: const Icon(Icons.update),
                label: const Text("NEU EINLESEN"),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: BimmerdashColors.bmwOrange,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    String title = info.modelSeries;
    if (info.modelYear > 0) {
      title += " (${info.modelYear})";
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_car, color: BimmerdashColors.bmwOrange, size: 32),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        info.manufacturer,
                        style: const TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 30),
            const Text(
              "FAHRZEUG-STECKBRIEF",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: BimmerdashColors.bmwOrange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: [
        _buildInfoTile("KILOMETERSTAND", "${info.mileage} km", Icons.speed),
        _buildInfoTile("PRODUKTION", info.productionDate.isEmpty ? "Unbekannt" : info.productionDate, Icons.calendar_today),
        _buildInfoTile("VIN (KURZ)", info.shortVin, Icons.vpn_key),
        _buildInfoTile("MODELLJAHR", info.modelYear > 0 ? info.modelYear.toString() : "N/A", Icons.history),
        _buildInfoTile("DME FLASH-ZYKLEN", "${info.flashCycles}", Icons.memory, subtitle: "Software & History"),
        _buildServiceTile("NÄCHSTER ÖLWECHSEL", info.oilServiceMileage, info.oilServiceDate, Icons.oil_barrel, subtitle: "Wartung"),
      ],
    );
  }

  Widget _buildServiceTile(String label, int restKm, String date, IconData icon, {String? subtitle}) {
    // Color logic: Orange if < 2000km or due soon, Red if overdue
    Color textColor = Colors.white70;
    
    // Check for overdue (simple check, assuming date is MM.YYYY)
    bool isOverdue = false;
    bool isUrgent = false;
    
    if (restKm <= 0) {
      isOverdue = true;
    } else if (restKm < 2000) {
      isUrgent = true;
    }

    if (isOverdue) {
      textColor = BimmerdashColors.redZone;
    } else if (isUrgent) {
      textColor = Colors.orange;
    }

    return Card(
      color: Colors.white.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (subtitle != null)
              Text(subtitle, style: const TextStyle(fontSize: 8, color: Colors.white24, fontWeight: FontWeight.bold)),
            Row(
              children: [
                Icon(icon, size: 14, color: Colors.grey),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              "in $restKm km\nam $date",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: textColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, IconData icon, {String? subtitle}) {
    return Card(
      color: Colors.white.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (subtitle != null)
              Text(subtitle, style: const TextStyle(fontSize: 8, color: Colors.white24, fontWeight: FontWeight.bold)),
            Row(
              children: [
                Icon(icon, size: 14, color: Colors.grey),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}
