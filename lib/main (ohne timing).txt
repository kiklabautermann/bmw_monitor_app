import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const BMWMonitorApp());
}

/// Definition eines anzeigbaren Parameters
class DisplayParam {
  final String id;
  final String label;
  final String unit;
  final String did; // Hex string e.g. "F45C"
  final double min;
  final double max;
  final Color color;
  final bool showRedZone;

  DisplayParam({
    required this.id,
    required this.label,
    required this.unit,
    required this.did,
    required this.min,
    required this.max,
    required this.color,
    this.showRedZone = false,
  });

  /// Berechnet den Wert basierend auf den empfangenen UDS Bytes
  double decode(Uint8List data) {
    if (data.length < 2) return 0.0;
    switch (id) {
      case 'oil_temp':
      case 'coolant':
      case 'iat':
      case 'gearbox_temp':
        return data[0].toDouble() - 40;
      case 'boost_alt': // hPa formula from previous code
        int hpa = (data[0] << 8) | data[1];
        double bar = (hpa - 1013) / 1000.0;
        return bar < 0 ? 0.0 : bar;
      case 'boost_act': // (Byte * 10) / 100 -> Bar
        return (data[0] * 10) / 100.0;
      default:
        return 0.0;
    }
  }

  static List<DisplayParam> available = [
    DisplayParam(id: 'oil_temp', label: "OIL TEMP", unit: "°C", did: "F45C", min: 60, max: 160, color: Colors.orange, showRedZone: true),
    DisplayParam(id: 'boost_alt', label: "BOOST (REL)", unit: "BAR", did: "D906", min: 0, max: 2.0, color: Colors.blue),
    DisplayParam(id: 'coolant', label: "COOLANT", unit: "°C", did: "F405", min: 60, max: 160, color: Colors.blueAccent, showRedZone: true),
    DisplayParam(id: 'iat', label: "INTAKE", unit: "°C", did: "F40F", min: 0, max: 100, color: Colors.cyan),
    DisplayParam(id: 'boost_act', label: "BOOST (ABS)", unit: "BAR", did: "D905", min: 0, max: 3.0, color: Colors.blue),
    DisplayParam(id: 'gearbox_temp', label: "GEARBOX", unit: "°C", did: "1E1E", min: 60, max: 160, color: Colors.redAccent),
  ];
}

class BMWMonitorApp extends StatelessWidget {
  const BMWMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
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
  // Aktuelle Werte
  double gaugeValueLeft = 0.0;
  double gaugeValueRight = 0.0;
  double peakLeft = 0.0;
  double peakRight = 0.0;
  
  // Konfigurierte Parameter
  DisplayParam leftParam = DisplayParam.available[0]; // Oil
  DisplayParam rightParam = DisplayParam.available[1]; // Boost Rel
  
  bool isConnected = false;
  bool isDiscovering = false;
  String statusText = "DISCONNECTED";
  
  Socket? _socket;
  Timer? _pollingTimer;
  
  String adapterIp = "192.168.16.103"; 
  int doipPort = 13400;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<File> _getSettingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, 'settings_v2.json'));
  }

  Future<void> _loadSettings() async {
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content);
        setState(() {
          adapterIp = json['ip'] ?? "192.168.16.103";
          doipPort = json['port'] ?? 13400;
          
          String leftId = json['left_param'] ?? 'oil_temp';
          String rightId = json['right_param'] ?? 'boost_alt';
          
          leftParam = DisplayParam.available.firstWhere((p) => p.id == leftId, orElse: () => DisplayParam.available[0]);
          rightParam = DisplayParam.available.firstWhere((p) => p.id == rightId, orElse: () => DisplayParam.available[1]);
          
          _resetPeaks();
        });
      }
    } catch (e) {
      debugPrint("Error loading settings: $e");
    }
  }

  Future<void> _saveSettings() async {
    try {
      final file = await _getSettingsFile();
      final json = jsonEncode({
        'ip': adapterIp,
        'port': doipPort,
        'left_param': leftParam.id,
        'right_param': rightParam.id
      });
      await file.writeAsString(json);
    } catch (e) {
      debugPrint("Error saving settings: $e");
    }
  }

  void _resetPeaks() {
    setState(() {
      peakLeft = leftParam.min;
      peakRight = rightParam.min;
      gaugeValueLeft = leftParam.min;
      gaugeValueRight = rightParam.min;
    });
  }

  /// DoIP UDP Discovery
  Future<void> _discoverAdapter() async {
    setState(() {
      isDiscovering = true;
      statusText = "DISCOVERING...";
    });
    try {
      RawDatagramSocket udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udpSocket.broadcastEnabled = true;
      final Uint8List request = Uint8List.fromList([0x02, 0xFD, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]);
      udpSocket.send(request, InternetAddress("255.255.255.255"), 13400);
      
      Timer(const Duration(seconds: 2), () {
        if (isDiscovering) {
          udpSocket.close();
          setState(() {
            isDiscovering = false;
            if (!isConnected) statusText = "NOT FOUND";
          });
        }
      });

      udpSocket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = udpSocket.receive();
          if (dg != null && dg.data.length >= 8 && dg.data[2] == 0x00 && dg.data[3] == 0x04) {
            setState(() {
              adapterIp = dg.address.address;
              isDiscovering = false;
              statusText = "FOUND: $adapterIp";
            });
            udpSocket.close();
            _saveSettings();
          }
        }
      });
    } catch (e) {
      setState(() { isDiscovering = false; statusText = "ERROR"; });
    }
  }

  void _showSettingsDialog() {
    final ipController = TextEditingController(text: adapterIp);
    final portController = TextEditingController(text: doipPort.toString());

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          title: const Text("Settings"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: ipController, decoration: const InputDecoration(labelText: "Adapter IP")),
                TextField(controller: portController, decoration: const InputDecoration(labelText: "DoIP Port"), keyboardType: TextInputType.number),
                const SizedBox(height: 20),
                const Text("Gauge Configuration", style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButtonFormField<String>(
                  value: leftParam.id,
                  decoration: const InputDecoration(labelText: "Left Gauge"),
                  items: DisplayParam.available.map((p) => DropdownMenuItem(value: p.id, child: Text(p.label))).toList(),
                  onChanged: (val) => setDialogState(() => leftParam = DisplayParam.available.firstWhere((p) => p.id == val)),
                ),
                DropdownButtonFormField<String>(
                  value: rightParam.id,
                  decoration: const InputDecoration(labelText: "Right Gauge"),
                  items: DisplayParam.available.map((p) => DropdownMenuItem(value: p.id, child: Text(p.label))).toList(),
                  onChanged: (val) => setDialogState(() => rightParam = DisplayParam.available.firstWhere((p) => p.id == val)),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () { Navigator.pop(context); _discoverAdapter(); },
                  icon: const Icon(Icons.search), label: const Text("Auto-Discover (UDP)"),
                )
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  adapterIp = ipController.text;
                  doipPort = int.tryParse(portController.text) ?? 13400;
                  _resetPeaks();
                });
                _saveSettings();
                Navigator.pop(context);
              },
              child: const Text("Save"),
            ),
          ],
        );
      }),
    );
  }

  Future<void> toggleConnection() async {
    if (isConnected) _disconnect(); else { _resetPeaks(); await _connect(); }
  }

  Future<void> _connect() async {
    setState(() => statusText = "CONNECTING...");
    try {
      _socket = await Socket.connect(adapterIp, doipPort, timeout: const Duration(seconds: 3));
      _socket!.add(Uint8List.fromList([0x02, 0xFD, 0x00, 0x05, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]));
      _socket!.listen(_onDataReceived, onError: (e) => _disconnect(), onDone: () => _disconnect());

      setState(() { isConnected = true; statusText = "CONNECTED"; });

      int toggle = 0;
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        _requestData(toggle == 0 ? leftParam : rightParam);
        toggle = toggle == 0 ? 1 : 0;
      });
    } catch (e) {
      setState(() => statusText = "FAILED");
      _disconnect();
    }
  }

  void _requestData(DisplayParam p) {
    if (_socket == null) return;
    // DID String parsen (z.B. "F45C" -> [0xF4, 0x5C])
    int b1 = int.parse(p.did.substring(0, 2), radix: 16);
    int b2 = int.parse(p.did.substring(2, 4), radix: 16);
    
    _socket!.add(Uint8List.fromList([
      0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x07, 0x0E, 0x00, 0x10, 0xF1, 0x03, 0x22, b1, b2
    ]));
  }

  void _onDataReceived(Uint8List data) {
    if (data.length < 15 || data[13] != 0x62) return;
    
    // Identifiziere welche DID geantwortet hat
    String receivedDid = data[14].toRadixString(16).padLeft(2, '0').toUpperCase() + 
                         data[15].toRadixString(16).padLeft(2, '0').toUpperCase();
    
    Uint8List payload = data.sublist(16);

    setState(() {
      if (receivedDid == leftParam.did.toUpperCase()) {
        gaugeValueLeft = leftParam.decode(payload);
        if (gaugeValueLeft > peakLeft) peakLeft = gaugeValueLeft;
      } else if (receivedDid == rightParam.did.toUpperCase()) {
        gaugeValueRight = rightParam.decode(payload);
        if (gaugeValueRight > peakRight) peakRight = gaugeValueRight;
      }
    });
  }

  void _disconnect() {
    _pollingTimer?.cancel();
    _socket?.destroy();
    _socket = null;
    setState(() { isConnected = false; statusText = "DISCONNECTED"; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        title: Row(
          children: [
            Image.asset('assets/mlogo.png', height: 30, errorBuilder: (c, e, s) => const Icon(Icons.drive_eta)),
            const SizedBox(width: 10),
            Text("M-Monitor", style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 5),
            Text(statusText, style: TextStyle(fontSize: 14, color: isConnected ? Colors.blue : (isDiscovering ? Colors.orange : Colors.red))),
          ],
        ),
        actions: [ IconButton(onPressed: _showSettingsDialog, icon: const Icon(Icons.settings)) ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: MGauge(value: gaugeValueLeft, peakValue: peakLeft, param: leftParam)),
                Expanded(child: MGauge(value: gaugeValueRight, peakValue: peakRight, param: rightParam)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 40.0),
            child: ElevatedButton(
              onPressed: isDiscovering ? null : toggleConnection,
              style: ElevatedButton.styleFrom(backgroundColor: isConnected ? Colors.red : const Color(0xFF00539F), minimumSize: const Size(200, 60)),
              child: Text(isConnected ? "STOP" : (isDiscovering ? "DISCOVERING..." : "CONNECT ENET WIFI")),
            ),
          )
        ],
      ),
    );
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
          CustomPaint(
              size: Size(size, size),
              painter: GaugePainter(
                  value: value, peakValue: peakValue, min: param.min, max: param.max, needleColor: param.color, showRedZone: param.showRedZone)),
          Positioned(
              bottom: size * 0.22,
              child: Column(children: [
                Text(param.max > 5 ? value.toInt().toString() : value.toStringAsFixed(2),
                    style: TextStyle(fontSize: size * 0.2, fontWeight: FontWeight.bold)),
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

    canvas.drawCircle(center, radius, Paint()..shader = RadialGradient(colors: [const Color(0xFF2A2A2A), Colors.black], stops: const [0.7, 1.0]).createShader(outerRect));
    canvas.drawCircle(center, radius, Paint()..color = Colors.grey[800]!..style = PaintingStyle.stroke..strokeWidth = 2);

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
        final textPainter = TextPainter(text: TextSpan(text: max > 5 ? val.toInt().toString() : val.toStringAsFixed(1), style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: radius * 0.12, fontWeight: FontWeight.w400, letterSpacing: -0.5)), textDirection: TextDirection.ltr);
        textPainter.layout();
        textPainter.paint(canvas, Offset(center.dx + textRadius * math.cos(angle) - textPainter.width / 2, center.dy + textRadius * math.sin(angle) - textPainter.height / 2));
      }
    }

    if (showRedZone && max > 100) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 8), (math.pi * 0.85) + ((120 - min) / (max - min) * math.pi * 1.3), ((max - 120) / (max - min) * math.pi * 1.3), false, Paint()..color = const Color(0xFFCE1237).withOpacity(0.8)..style = PaintingStyle.stroke..strokeWidth = 3);
    }

    final angle = (math.pi * 0.85) + (((value - min) / (max - min)).clamp(0.0, 1.0) * math.pi * 1.3);
    canvas.drawLine(Offset(center.dx + 3.0, center.dy + 3.0), Offset(center.dx + (radius * 0.8) * math.cos(angle) + 3.0, center.dy + (radius * 0.8) * math.sin(angle) + 3.0), Paint()..color = Colors.black.withOpacity(0.5)..strokeWidth = 4..strokeCap = StrokeCap.round);
    canvas.drawLine(center, Offset(center.dx + (radius * 0.82) * math.cos(angle), center.dy + (radius * 0.82) * math.sin(angle)), Paint()..color = needleColor..strokeWidth = 3.5..strokeCap = StrokeCap.round);
    canvas.drawCircle(center, radius * 0.1, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(center, radius * 0.08, Paint()..color = const Color(0xFF333333));
  }

  @override bool shouldRepaint(covariant GaugePainter old) => true;
}
