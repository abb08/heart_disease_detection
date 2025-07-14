import 'dart:io';
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
  runApp(HeartDiseaseDetectionApp());
}

class HeartDiseaseDetectionApp extends StatelessWidget {
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
  List<double>? _waveformData;

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
          await _classifyAudio(_recordedFilePath!);
        } else {
          _showError("Recording file is empty or does not exist.");
        }
      }
    } catch (e) {
      _showError("Error stopping recording: $e");
    }
  }

  Future<void> _classifyAudio(String path) async {
    if (_interpreter == null) {
      _showError("Interpreter is not initialized. Please try again.");
      return;
    }

    setState(() {
      _isProcessing = true;
      _waveformData = null;
    });

    try {
      final File audioFile = File(path);

      final List<List<List<List<double>>>> inputTensor =
      await _preprocessAudio(audioFile);

      final List<List<double>> outputTensor =
      List.generate(1, (_) => List.filled(1, 0.0));

      _interpreter!.run(inputTensor, outputTensor);

      final double predictionValue = outputTensor[0][0];

      setState(() {
        _prediction = predictionValue > 0.5
            ? "Prediction: Healthy"
            : "Prediction: Unhealthy";
        _predictionColor = predictionValue > 0.5 ? Colors.green : Color(0xffC93C3E);
      });

      await _playAudio(path);
    } catch (e) {
      _showError("Error during classification: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _playAudio(String filePath) async {
    try {
      await _audioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      await _audioPlayer.setSourceDeviceFile(filePath);
      await _audioPlayer.resume();
    } catch (e) {
      _showError("Error playing audio: $e");
    }
  }

  Future<List<List<List<List<double>>>>> _preprocessAudio(
      File audioFile) async {
    try {
      final wavFile = await Wav.readFile(audioFile.path);
      List<double> samples = wavFile.channels[0];
      samples = _truncateOrPad(samples, 40000);

      setState(() => _waveformData = samples);

      final List<List<double>> spectrogram = _computeSTFT(samples, 80, 40);

      return List.generate(
        1,
            (_) => List.generate(
          spectrogram.length,
              (i) => List.generate(65, (j) => [spectrogram[i][j]]),
        ),
      );
    } catch (e) {
      _showError("Error during audio preprocessing: $e");
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
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.single.path != null) {
        String filePath = result.files.single.path!;
        await _classifyAudio(filePath);
      }
    } catch (e) {
      _showError("Error picking audio file: $e");
    }
  }

  void _showError(String message) {
    final context = this.context;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: TextStyle(color: Colors.white)),
          backgroundColor: Color(0xffC93C3E),
          duration: Duration(seconds: 100),
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
                fontSize: MediaQuery.of(context).size.height / 35,
              ),
            ),
            SizedBox(height: MediaQuery.of(context).size.height / 18),
            _waveformData != null
                ? Container(
              margin: EdgeInsets.symmetric(
                  horizontal: MediaQuery.of(context).size.height / 50),
              height: MediaQuery.of(context).size.height / 4,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
              ),
              child: CustomPaint(
                painter: WaveformPainter(_waveformData!, _predictionColor),
              ),
            )
                : Image(
                image: AssetImage(
                  "assets/undraw_medicine_hqqg 1.png",
                )),
            if (_isProcessing) CircularProgressIndicator(),
            Padding(
              padding: EdgeInsets.symmetric(
                  vertical: MediaQuery.of(context).size.height / 80),
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
                    vertical: MediaQuery.of(context).size.height / 160),
                decoration: BoxDecoration(
                  color: Color(0xffCC93C3E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    'Pick Audio File',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize:
                        MediaQuery.of(context).size.height / 42),
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
                    vertical: MediaQuery.of(context).size.height / 160),
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
  final List<double> waveData;
  final Color waveColor;

  WaveformPainter(this.waveData, this.waveColor);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = waveColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final midHeight = size.height / 2;
    final widthStep = size.width / waveData.length;

    final path = Path();
    path.moveTo(0, midHeight);

    for (int i = 0; i < waveData.length; i++) {
      final x = i * widthStep;
      final y = midHeight - (waveData[i] * midHeight);
      path.lineTo(x, y);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
