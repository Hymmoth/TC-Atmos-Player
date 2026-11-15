# Modifiche a mpv

`mpv-coreaudio-discrete.patch`: quando il motore Atmos manda i canali "per indice"
(nessuna etichetta di posizione, il caso normale), mpv su macOS cerca di farli
combaciare con la configurazione altoparlanti di Configurazione MIDI Audio e
spesso finisce per ridurli a stereo. Con la modifica, se il dispositivo ha abbastanza
uscite, i canali vanno in ordine 1:1 sulle uscite (layout CoreAudio
"DiscreteInOrder"), senza nessun rimescolamento.
