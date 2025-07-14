/*
* import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:wav/wav.dart';
import 'package:fftea/fftea.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(HeartDiseaseApp());
}

class HeartDiseaseApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AudioClassifier(),
    );
  }
}

class AudioClassifier extends StatefulWidget {
  @override
  _AudioClassifierState createState() => _AudioClassifierState();
}

class _AudioClassifierState extends State<AudioClassifier> {
  String _prediction = "Select or record an audio";
  Interpreter? _interpreter;
  Color _predictionColor = Color(0xFFC93C3E);
  AudioPlayer _audioPlayer = AudioPlayer();
  bool _isProcessing = false;
  List<double>? _waveformData; // Raw waveform data

  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder();
  bool _isRecording = false;
  String? _recordedFilePath;

  @override
  void initState() {
    super.initState();
    _initializeRecorder();
    _loadModel();
  }

  Future<void> _initializeRecorder() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        await _audioRecorder.openRecorder();
      } else {
        _showError("Microphone permission not granted.");
        throw Exception("Microphone permission not granted.");
      }
    } catch (e) {
      _showError("Error initializing recorder: $e");
    }
  }

  Future<void> _loadModel() async {
    try {
      final interpreterOptions = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset(
        'assets/ASL_TFLite.tflite',
        options: interpreterOptions,
      );
    } catch (e) {
      _showError("Failed to load model: $e");
      _interpreter = null;
    }
  }

  Future<void> _startRecording() async {
    try {
      if (!_isRecording) {
        final directory = await getTemporaryDirectory();
        _recordedFilePath = "${directory.path}/recorded_audio.wav";

        await _audioRecorder.startRecorder(
          toFile: _recordedFilePath,
          codec: Codec.pcm16WAV,
        );

        setState(() => _isRecording = true);
      } else {
        _showError("Recorder is already running.");
      }
    } catch (e) {
      _showError("Error starting recording: $e");
    }
  }

  Future<void> _stopRecording() async {
    try {
      await _audioRecorder.stopRecorder();
      setState(() => _isRecording = false);

      if (_recordedFilePath != null) {
        final file = File(_recordedFilePath!);
        if (await file.exists() && await file.length() > 0) {
          await _extractWaveform(file); // Extract waveform immediately after recording
        } else {
          _showError("Recording file is empty or does not exist.");
        }
      }
    } catch (e) {
      _showError("Error stopping recording: $e");
    }
  }

  Future<void> _extractWaveform(File audioFile) async {
    try {
      final wavFile = await Wav.readFile(audioFile.path);
      final samples = wavFile.channels[0]; // Extract the first channel (mono)
      setState(() {
        _waveformData = samples; // Store raw waveform data
      });
    } catch (e) {
      _showError("Error extracting waveform: $e");
    }
  }

  Future<void> _pickAudioFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.single.path != null) {
        String filePath = result.files.single.path!;
        final file = File(filePath);
        await _extractWaveform(file); // Extract waveform immediately after picking
      }
    } catch (e) {
      _showError("Error picking audio file: $e");
    }
  }

  void _showError(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    });
    print(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: MediaQuery.of(context).size.height / 10),
            Text(
              'Heart Disease Detection',
              style: TextStyle(
                color: Color(0xffC93C3E),
                fontWeight: FontWeight.bold,
                fontSize: MediaQuery.of(context).size.height / 36,
              ),
            ),
            SizedBox(height: MediaQuery.of(context).size.height / 18),
            _waveformData != null
                ? Container(
              margin: EdgeInsets.symmetric(
                horizontal: MediaQuery.of(context).size.height / 50,
              ),
              height: MediaQuery.of(context).size.height / 4,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Color(0xffC93C3E), width: 2),
              ),
              child: CustomPaint(
                painter: WaveformPainter(_waveformData!),
              ),
            )
                : Image(
              image: AssetImage(
                "assets/undraw_medicine_hqqg 1.png",
              ),
            ),
            if (_isProcessing) CircularProgressIndicator(),
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: MediaQuery.of(context).size.height / 80,
              ),
              child: Text(
                '$_prediction',
                style: TextStyle(
                  color: _predictionColor,
                  fontWeight: FontWeight.bold,
                  fontSize: MediaQuery.of(context).size.height / 35,
                ),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).size.height / 5),
            _isRecording == false
                ? InkWell(
              onTap: _pickAudioFile,
              child: Container(
                height: MediaQuery.of(context).size.height / 16,
                margin: EdgeInsets.symmetric(
                  horizontal: MediaQuery.of(context).size.height / 12,
                  vertical: MediaQuery.of(context).size.height / 160,
                ),
                decoration: BoxDecoration(
                  color: Color(0xffCC93C3E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    'Pick Audio File',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: MediaQuery.of(context).size.height / 42,
                    ),
                  ),
                ),
              ),
            )
                : SizedBox(
              height: MediaQuery.of(context).size.height / 20,
            ),
            InkWell(
              onTap: _isRecording ? _stopRecording : _startRecording,
              child: Container(
                height: MediaQuery.of(context).size.height / 16,
                margin: EdgeInsets.symmetric(
                  horizontal: MediaQuery.of(context).size.height / 12,
                  vertical: MediaQuery.of(context).size.height / 160,
                ),
                decoration: BoxDecoration(
                  color: Color(0xffCC93C3E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(
                        _isRecording ? Icons.pause : Icons.play_arrow_sharp,
                        size: MediaQuery.of(context).size.height / 35,
                        color: Colors.white,
                      ),
                      Text(
                        _isRecording ? 'Stop Recording' : 'Record Audio',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: MediaQuery.of(context).size.height / 42,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioRecorder.closeRecorder();
    _audioPlayer.dispose();
    _interpreter?.close();
    super.dispose();
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> waveform;

  WaveformPainter(this.waveform);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    final middle = size.height / 2;
    final scaleFactor = size.height / waveform.reduce((a, b) => max(a.abs(), b.abs()));

    for (int i = 0; i < waveform.length; i++) {
      final x = (i / waveform.length) * size.width;
      final y = middle - waveform[i] * scaleFactor;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
*/