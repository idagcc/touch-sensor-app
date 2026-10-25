// Test buttons that simulate the sensor's classified gestures.
// Wire momentary switches between pins 2/3 and GND.
// INPUT_PULLUP: pressed is LOW. Send once per press, not while held.
const byte pins[] = {2, 3};
const char* commands[] = {"0", "1"}; // single touch: play/pause; double tap: return to holding
bool stable[] = {HIGH, HIGH};
bool previous[] = {HIGH, HIGH};
unsigned long changedAt[] = {0, 0};
unsigned long lastHeartbeat = 0;

void setup() {
  Serial.begin(9600);
  for (byte i = 0; i < 2; i++) pinMode(pins[i], INPUT_PULLUP);
  // Optional status protocol understood by Touch Player; never sent as a gesture.
  Serial.println("READY");
}

void loop() {
  if (millis() - lastHeartbeat >= 1000) {
    Serial.println("HEARTBEAT");
    lastHeartbeat = millis();
  }
  for (byte i = 0; i < 2; i++) {
    bool reading = digitalRead(pins[i]);
    if (reading != previous[i]) changedAt[i] = millis();
    if (millis() - changedAt[i] >= 40 && reading != stable[i]) {
      stable[i] = reading;
      if (reading == LOW) Serial.println(commands[i]);
    }
    previous[i] = reading;
  }
}
