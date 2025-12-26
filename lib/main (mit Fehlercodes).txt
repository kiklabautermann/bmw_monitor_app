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

void main() {
  runApp(const BMWMonitorApp());
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

  DisplayParam({
    required this.id, required this.label, required this.unit,
    required this.did, required this.min, required this.max, 
    required this.color, this.showRedZone = false,
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
      default: return 0.0;
    }
  }

  static List<DisplayParam> available = [
    DisplayParam(id: 'oil_temp', label: "OIL TEMP", unit: "°C", did: "F45C", min: 60, max: 160, color: Colors.orange, showRedZone: true),
    DisplayParam(id: 'boost', label: "BOOST", unit: "BAR", did: "D906", min: 0, max: 2.0, color: Colors.blue),
    DisplayParam(id: 'timing_all', label: "TIMING", unit: "°KW", did: "D011", min: -10, max: 0, color: Colors.red),
    DisplayParam(id: 'coolant', label: "WATER", unit: "°C", did: "F405", min: 60, max: 160, color: Colors.blueAccent, showRedZone: true),
    DisplayParam(id: 'iat', label: "INTAKE", unit: "°C", did: "F40F", min: 0, max: 100, color: Colors.cyan),
  ];
}

class BMWMonitorApp extends StatelessWidget {
  const BMWMonitorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
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
  double gaugeValueLeft = 0.0;
  double gaugeValueRight = 0.0;
  double peakLeft = 0.0;
  double peakRight = 0.0;
  List<double> cylinderCorrections = List.filled(6, 0.0);
  double worstTimingCorrection = 0.0;
  int worstCylinder = 0;

  DisplayParam leftParam = DisplayParam.available[0];
  DisplayParam rightParam = DisplayParam.available[2];

  bool isConnected = false;
  bool isDiscovering = false;
  String statusText = "DISCONNECTED";
  Socket? _socket;
  Timer? _pollingTimer;
  String adapterIp = "192.168.16.103";
  int doipPort = 13400;

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
          leftParam = DisplayParam.available.firstWhere((p) => p.id == json['left_id'], orElse: () => DisplayParam.available[0]);
          rightParam = DisplayParam.available.firstWhere((p) => p.id == json['right_id'], orElse: () => DisplayParam.available[2]);
        });
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    final file = await _getSettingsFile();
    await file.writeAsString(jsonEncode({
      'ip': adapterIp, 'port': doipPort, 'left_id': leftParam.id, 'right_id': rightParam.id
    }));
  }

  // --- UDP DISCOVERY ---
  Future<void> _discoverAdapter() async {
    setState(() { isDiscovering = true; statusText = "SCANNING..."; });
    try {
      RawDatagramSocket udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udpSocket.broadcastEnabled = true;
      udpSocket.send(Uint8List.fromList([0x02, 0xFD, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]), InternetAddress("255.255.255.255"), 13400);
      
      udpSocket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = udpSocket.receive();
          if (dg != null && dg.data.length >= 8) {
            setState(() { adapterIp = dg.address.address; isDiscovering = false; statusText = "FOUND: $adapterIp"; });
            udpSocket.close();
            _saveSettings();
          }
        }
      });
      Future.delayed(const Duration(seconds: 3), () { if (isDiscovering) { udpSocket.close(); setState(() { isDiscovering = false; statusText = "NOT FOUND"; }); } });
    } catch (e) { setState(() { isDiscovering = false; statusText = "UDP ERROR"; }); }
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

    // Send VIN request (DID F190)
    _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x22, 0xF1, 0x90]));
  }

  void _processVinResponse(Uint8List data) {
    if (data.length < 17 || data[13] != 0x62) return;

    // Extract VIN from response (ASCII bytes)
    Uint8List vinBytes = data.sublist(16);
    String vin = String.fromCharCodes(vinBytes).trim();

    // Extract model code (positions 4-7, 0-based index 3-6)
    if (vin.length >= 7) {
      String modelCode = vin.substring(3, 7);
      String modelName = _modelDb[modelCode] ?? "BMW (Code: $modelCode)";

      // Determine cylinder count based on model name
      int cylinders = 6;
      if (modelName.contains(RegExp(r'(120i|125i|135i|230i|320i|330i|420i|430i|MINI)'))) {
        cylinders = 4;
      }

      if (mounted) {
        setState(() {
          vinDisplay = vin;
          carModel = modelName;
          cylinderCount = cylinders;
          // Resize cylinderCorrections array to match cylinder count
          cylinderCorrections = List.filled(cylinders, 0.0);
        });
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nicht verbunden. Bitte zuerst Verbindung herstellen.")),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fehler beim Auslesen der Fehlercodes.")),
      );
    }
  }

  Future<void> _clearDtcs() async {
    if (_socket == null || !isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nicht verbunden. Bitte zuerst Verbindung herstellen.")),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Fehlerspeicher wurde gelöscht")),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isClearingDTCs = false;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fehler beim Löschen der Fehlercodes.")),
      );
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
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Konnte URL nicht öffnen: $url')),
      );
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

      // Load vehicle models and request VIN
      await _loadVehicleModels();
      await _requestVehicleIdentification();

      int pollStep = 0;
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
        if (_socket == null) return;
        if (pollStep == 0) _sendRequest(leftParam.did);
        else if (pollStep == 1) _sendRequest(rightParam.did);
        else {
          // Skip cylinders 5 and 6 for 4-cylinder engines
          int cylinderIndex = pollStep - 2;
          if (cylinderCount == 4 && (cylinderIndex == 4 || cylinderIndex == 5)) {
            // Skip this step, but still increment pollStep
            pollStep = (pollStep + 1);
            if (cylinderCount == 4) {
              // For 4-cylinder, cycle through 6 steps instead of 8
              pollStep = pollStep % 6;
            } else {
              pollStep = pollStep % 8;
            }
            return;
          }
          _sendRequest("D0${11 + cylinderIndex}");
        }
        pollStep = (pollStep + 1);
        if (cylinderCount == 4) {
          // For 4-cylinder engines, cycle through 6 steps instead of 8
          pollStep = pollStep % 6;
        } else {
          pollStep = pollStep % 8;
        }
      });
    } catch (e) { setState(() => statusText = "FAILED"); _disconnect(); }
  }

  void _sendRequest(String didStr) {
    int b1 = int.parse(didStr.substring(0, 2), radix: 16);
    int b2 = int.parse(didStr.substring(2, 4), radix: 16);
    _socket?.add(Uint8List.fromList([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x22, b1, b2]));
  }

  void _onDataReceived(Uint8List data) {
    if (data.length < 17) return;

    // Handle different response types
    if (data[13] == 0x62) {
      // Standard data response
      String rDid = data[14].toRadixString(16).padLeft(2, '0').toUpperCase() + data[15].toRadixString(16).padLeft(2, '0').toUpperCase();
      Uint8List pld = data.sublist(16);

      // Handle VIN response (DID F190)
      if (rDid == "F190") {
        _processVinResponse(data);
      }

      setState(() {
        if (rDid == leftParam.did) { gaugeValueLeft = leftParam.decode(pld); if (gaugeValueLeft > peakLeft) peakLeft = gaugeValueLeft; }
        else if (rDid == rightParam.did) { gaugeValueRight = rightParam.decode(pld); if (gaugeValueRight > peakRight) peakRight = gaugeValueRight; }
        else if (rDid.startsWith("D01")) {
          int idx = int.parse(rDid.substring(3)) - 1;
          double cr = (pld[0] - 128) * 0.1;
          cylinderCorrections[idx] = cr;
          if (cr < worstTimingCorrection) { worstTimingCorrection = cr; worstCylinder = idx + 1; }
        }
      });
    } else if (data[13] == 0x59) {
      // DTC response (Service 0x59)
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
        carModel = "BMW Performance";
        vinDisplay = "";
        cylinderCount = 6;
        cylinderCorrections = List.filled(6, 0.0);
      });
    }
  }

  void _showSettings() {
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Settings"),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(decoration: const InputDecoration(labelText: "IP"), controller: TextEditingController(text: adapterIp), onChanged: (v) => adapterIp = v),
        ElevatedButton(onPressed: () { Navigator.pop(context); _discoverAdapter(); }, child: const Text("Auto-Discover (UDP)")),
        DropdownButtonFormField<String>(value: leftParam.id, items: DisplayParam.available.map((p) => DropdownMenuItem(value: p.id, child: Text(p.label))).toList(), onChanged: (id) => setState(() => leftParam = DisplayParam.available.firstWhere((p) => p.id == id))),
        DropdownButtonFormField<String>(value: rightParam.id, items: DisplayParam.available.map((p) => DropdownMenuItem(value: p.id, child: Text(p.label))).toList(), onChanged: (id) => setState(() => rightParam = DisplayParam.available.firstWhere((p) => p.id == id))),
      ])),
      actions: [TextButton(onPressed: () { _saveSettings(); Navigator.pop(context); }, child: const Text("Save & Close"))],
    ));
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
        backgroundColor: const Color(0xFF121212),
        title: Row(children: [
          Image.asset('assets/mlogo.png', height: 25, errorBuilder: (c, e, s) => const Icon(Icons.drive_eta)),
          const SizedBox(width: 8),
          // Compact connection status indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isConnected ? Colors.blue.withOpacity(0.2) : Colors.red.withOpacity(0.2),
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
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(carModel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue)),
                if (vinDisplay.isNotEmpty)
                  Text(vinDisplay, style: const TextStyle(fontSize: 10, color: Colors.white24)),
              ],
            ),
          ),
        ]),
        actions: [
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
            onPressed: isDiscovering ? null : (isConnected ? _disconnect : _connect),
            color: isConnected ? Colors.red : Colors.blue,
          ),
        ],
      ),
      body: Column(children: [
        _buildWorstCaseBar(),
        Expanded(child: Row(children: [
          Expanded(child: _buildTile(leftParam, gaugeValueLeft, peakLeft)),
          Expanded(child: _buildTile(rightParam, gaugeValueRight, peakRight)),
        ])),
      ]),
    );
  }

  Widget _buildWorstCaseBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      color: Colors.white.withOpacity(0.05),
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
    return MGauge(value: val, peakValue: peak, param: p);
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
          Expanded(child: Container(height: 10, decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(2)), child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: (corrections[i] / min).clamp(0.0, 1.0), child: Container(decoration: BoxDecoration(color: corrections[i] < -3 ? Colors.red : Colors.orange, borderRadius: BorderRadius.circular(2)))))),
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
  const MGauge({super.key, required this.value, required this.peakValue, required this.param});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      double size = math.min(constraints.maxWidth, constraints.maxHeight * 0.85);
      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(param.label, style: TextStyle(fontSize: size * 0.07, fontWeight: FontWeight.bold, color: Colors.grey[400])),
        SizedBox(height: size * 0.05),
        Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size(size, size), painter: GaugePainter(value: value, peakValue: peakValue, min: param.min, max: param.max, needleColor: param.color, showRedZone: param.showRedZone)),
          Positioned(bottom: size * 0.22, child: Column(children: [
            Text(param.max > 5 ? value.toInt().toString() : value.toStringAsFixed(2), style: TextStyle(fontSize: size * 0.2, fontWeight: FontWeight.bold)),
            Text(param.unit, style: TextStyle(fontSize: size * 0.07, color: Colors.grey)),
          ]))
        ])
      ]);
    });
  }
}

class GaugePainter extends CustomPainter {
  final double value, peakValue, min, max;
  final Color needleColor;
  final bool showRedZone;
  GaugePainter({required this.value, required this.peakValue, required this.min, required this.max, required this.needleColor, required this.showRedZone});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final outerRect = Rect.fromCircle(center: center, radius: radius);

    // Background Gradient
    canvas.drawCircle(center, radius, Paint()..shader = RadialGradient(colors: [const Color(0xFF2A2A2A), Colors.black], stops: const [0.7, 1.0]).createShader(outerRect));
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
        Paint()..color = isMajor ? Colors.white.withOpacity(0.9) : Colors.white.withOpacity(0.4)..strokeWidth = isMajor ? 2.5 : 1.2..strokeCap = StrokeCap.round,
      );

      if (isMajor && i % 10 == 0) {
        final val = min + (i / 50 * (max - min));
        if (max > 100 && (val < 60 || val > 160)) continue;
        final textRadius = startRadius - tickLength - 15;
        final textPainter = TextPainter(text: TextSpan(text: max > 5 ? val.toInt().toString() : val.toStringAsFixed(1), style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: radius * 0.12, fontWeight: FontWeight.w400)), textDirection: TextDirection.ltr);
        textPainter.layout();
        textPainter.paint(canvas, Offset(center.dx + textRadius * math.cos(angle) - textPainter.width / 2, center.dy + textRadius * math.sin(angle) - textPainter.height / 2));
      }
    }

    // Red Zone
    if (showRedZone && max > 100) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 8), (math.pi * 0.85) + ((120 - min) / (max - min) * math.pi * 1.3), ((max - 120) / (max - min) * math.pi * 1.3), false, Paint()..color = const Color(0xFFCE1237).withOpacity(0.8)..style = PaintingStyle.stroke..strokeWidth = 3);
    }

    // Needle Shadow & Needle
    final angle = (math.pi * 0.85) + (((value - min) / (max - min)).clamp(0.0, 1.0) * math.pi * 1.3);
    canvas.drawLine(Offset(center.dx + 3.0, center.dy + 3.0), Offset(center.dx + (radius * 0.8) * math.cos(angle) + 3.0, center.dy + (radius * 0.8) * math.sin(angle) + 3.0), Paint()..color = Colors.black.withOpacity(0.5)..strokeWidth = 4..strokeCap = StrokeCap.round);
    canvas.drawLine(center, Offset(center.dx + (radius * 0.82) * math.cos(angle), center.dy + (radius * 0.82) * math.sin(angle)), Paint()..color = needleColor..strokeWidth = 3.5..strokeCap = StrokeCap.round);
    
    // Center Hub
    canvas.drawCircle(center, radius * 0.1, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(center, radius * 0.08, Paint()..color = const Color(0xFF333333));
  }
  @override bool shouldRepaint(covariant GaugePainter old) => true;
}
