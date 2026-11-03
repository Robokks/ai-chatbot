/// One application can provide AI, consume it, or pass it to another subnet.
enum LabRole {
  main('Main', 'This PC has internet. Share AI and manage access for lab PCs.'),
  client('Client', 'Connect to Main for AI. Tools run on this PC.'),
  relay('Relay', 'Connect upstream and share access with PCs behind this PC.');

  const LabRole(this.label, this.description);
  final String label;
  final String description;
}
