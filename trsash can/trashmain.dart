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

void main() async{
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
      title: 'Heart Disease Detection',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: AudioClassifier(),
    );
  }
}

class AudioClassifier extends StatefulWidget {
  @override
  _AudioClassifierState createState() => _AudioClassifierState();
}

class _AudioClassifierState extends State<AudioClassifier> {
  String _prediction = "Select or record an audio file";
  Interpreter? _interpreter; // Nullable
  Color _predictionColor = Colors.black;
  AudioPlayer _audioPlayer = AudioPlayer();
  bool _isProcessing = false;
  List<String> _logMessages = [];
  List<List<double>>? _spectrogramData;

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
      _log("Initializing recorder...");
      if (await Permission.microphone.request().isGranted) {
        await _audioRecorder.openRecorder();
        _log("Recorder initialized successfully.");
      } else {
        _log("Microphone permission not granted.");
        throw Exception("Microphone permission not granted.");
      }
    } catch (e) {
      _log("Error initializing recorder: $e");
    }
  }

  Future<void> _loadModel() async {
    try {
      _log("Loading model...");
      final interpreterOptions = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset(
        'assets/ASL_TFLite.tflite',
        options: interpreterOptions,
      );
      _log("Model loaded successfully.");
    } catch (e) {
      _log("Failed to load model: $e");
      _interpreter = null;
    }
  }

  Future<void> _startRecording() async {
    try {
      if (!_isRecording) {
        final directory = await getTemporaryDirectory();
        _recordedFilePath = "${directory.path}/recorded_audio.wav";

        _log("Starting recording...");
        await _audioRecorder.startRecorder(
          toFile: _recordedFilePath,
          codec: Codec.pcm16WAV,
        );

        setState(() => _isRecording = true);
        _log("Recording started.");
      } else {
        _log("Recorder is already running.");
      }
    } catch (e) {
      _log("Error starting recording: $e");
    }
  }

  Future<void> _stopRecording() async {
    try {
      _log("Stopping recording...");
      await _audioRecorder.stopRecorder();
      setState(() => _isRecording = false);

      if (_recordedFilePath != null) {
        final file = File(_recordedFilePath!);
        if (await file.exists() && await file.length() > 0) {
          _log("Recording saved at: $_recordedFilePath");
          await _classifyAudio(_recordedFilePath!);
        } else {
          _log("Recording file is empty or does not exist.");
        }
      }
    } catch (e) {
      _log("Error stopping recording: $e");
    }
  }

  Future<void> _classifyAudio(String path) async {
    if (_interpreter == null) {
      _log("Interpreter is not initialized. Please try again.");
      return;
    }

    setState(() {
      _isProcessing = true;
      _logMessages.clear();
      _spectrogramData = null;
    });

    try {
      _log("Reading and preprocessing audio file...");
      final File audioFile = File(path);

      final List<List<List<List<double>>>> inputTensor =
      await _preprocessAudio(audioFile);

      _log("Running model inference...");
      final List<List<double>> outputTensor =
      List.generate(1, (_) => List.filled(1, 0.0));

      _interpreter!.run(inputTensor, outputTensor);

      final double predictionValue = outputTensor[0][0];
      _log("Raw Output: $predictionValue");

      setState(() {
        _prediction = predictionValue > 0.5 ? "Healthy" : "Unhealthy";
        _predictionColor = predictionValue > 0.5 ? Colors.green : Colors.red;
      });

      // Play the audio file after obtaining prediction
      await _playAudio(path);
    } catch (e) {
      _log("Error during classification: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _playAudio(String filePath) async {
    try {
      _log("Playing audio...");
      await _audioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      await _audioPlayer.setSourceDeviceFile(filePath);
      await _audioPlayer.resume();
      _log("Audio playback started.");
    } catch (e) {
      _log("Error playing audio: $e");
    }
  }

  Future<List<List<List<List<double>>>>> _preprocessAudio(File audioFile) async {
    try {
      final wavFile = await Wav.readFile(audioFile.path);
      List<double> samples = wavFile.channels[0];
      samples = _truncateOrPad(samples, 40000);

      final List<List<double>> spectrogram = _computeSTFT(samples, 80, 40);
      setState(() => _spectrogramData = spectrogram);

      _log("Audio file processed successfully.");
      return List.generate(
        1,
            (_) => List.generate(
          spectrogram.length,
              (i) => List.generate(65, (j) => [spectrogram[i][j]]),
        ),
      );
    } catch (e) {
      _log("Error during audio preprocessing: $e");
      rethrow;
    }
  }

  List<double> _truncateOrPad(List<double> samples, int targetLength) {
    if (samples.length > targetLength) {
      return samples.sublist(0, targetLength);
    } else if (samples.length < targetLength) {
      return samples + List<double>.filled(targetLength - samples.length, 0.0);
    }
    return samples;
  }

  List<List<double>> _computeSTFT(
      List<double> signal, int frameLength, int frameStep) {
    int signalLength = signal.length;
    int numFrames = ((signalLength - frameLength) / frameStep).ceil() + 1;

    return List.generate(numFrames, (i) {
      int start = i * frameStep;
      int end = min(start + frameLength, signalLength);
      List<double> frame = signal.sublist(start, end);
      if (frame.length < frameLength) {
        frame.addAll(List<double>.filled(frameLength - frame.length, 0.0));
      }
      frame = _applyHammingWindow(frame);

      final fFt = FFT(frame.length);
      final fftResult = fFt.realFft(frame);

      return fftResult.sublist(0, 65).map((complex) {
        return sqrt(complex.x * complex.x + complex.y * complex.y);
      }).toList();
    });
  }

  List<double> _applyHammingWindow(List<double> frame) {
    int N = frame.length;
    return List.generate(
      N,
          (n) => frame[n] * (0.54 - 0.46 * cos(2 * pi * n / (N - 1))),
    );
  }

  Future<void> _pickAudioFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null && result.files.single.path != null) {
      String filePath = result.files.single.path!;
      _log("Picked file path: $filePath");
      await _classifyAudio(filePath);
    }
  }

  void _log(String message) {
    setState(() {
      _logMessages.add(message);
      print(message); // Ensure logs are printed
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('Heart Disease Detection'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_spectrogramData != null)
              Container(
                height: 200,
                width: double.infinity,
                color: Colors.black,
                child: CustomPaint(
                  painter: SpectrogramPainter(_spectrogramData!),
                ),
              ),
            if (_isProcessing) CircularProgressIndicator(),
            Text(
              'Prediction: $_prediction',
              style: TextStyle(fontSize: 20, color: _predictionColor),
            ),
            ElevatedButton(
              onPressed: _pickAudioFile,
              child: Text('Pick Audio File'),
            ),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : _startRecording,
              child: Text(_isRecording ? 'Stop Recording' : 'Record Audio'),
            ),
            if (_logMessages.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: _logMessages
                      .map((log) => Text(log, style: TextStyle(fontSize: 12)))
                      .toList(),
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

class SpectrogramPainter extends CustomPainter {
  final List<List<double>> spectrogramData;

  SpectrogramPainter(this.spectrogramData);

  @override
  void paint(Canvas canvas, Size size) {
    final columnWidth = size.width / spectrogramData.length;
    final rowHeight = size.height / spectrogramData[0].length;

    final paint = Paint();

    for (int i = 0; i < spectrogramData.length; i++) {
      for (int j = 0; j < spectrogramData[i].length; j++) {
        final value = spectrogramData[i][j];
        paint.color = Color.lerp(Colors.black, Colors.green, value)!;
        canvas.drawRect(
          Rect.fromLTWH(i * columnWidth, j * rowHeight, columnWidth, rowHeight),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
*/