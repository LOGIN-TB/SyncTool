# Fassung und Baunummer

Zurück zur [Übersicht](../README.md).

Oben im Statusfenster stehen Programmname und Fassung, etwa `1.4.0`. Der
Mauszeiger darüber zeigt zusätzlich die Baunummer. Beides steht in
`macos/VERSION`:

```
1.4.0
2026.08.20-3
```

Die beiden Zahlen beantworten verschiedene Fragen:

- Die **Fassung** sagt, welcher Quellstand läuft. Sie muss auf allen Rechnern
  gleich sein, sonst laufen dort verschiedene Programme. Angehoben wird sie von
  Hand: `make release VERSION=1.5.0`.
- Die **Baunummer** sagt, welches Binary läuft. Sie besteht aus dem Baudatum und
  einem Zähler, der bei mehreren Bauten am selben Tag hochgeht. Das Bauskript
  setzt sie selbst, vergessen kann man sie also nicht.

Wer auf zwei Rechnern aus demselben Quellstand selbst baut, bekommt zwei
verschiedene Baunummern bei gleicher Fassung. Das ist richtig so: es sind zwei
Bauten desselben Programms.

```bash
make version
```

**Zeile 2 nie von Hand ändern.** Wer den Zähler für einen Lauf anhalten muss,
setzt `SYNCTOOL_KEEP_VERSION=1`. Das braucht der Release-Weg, weil jede
Änderung an `VERSION` den Arbeitsbaum schmutzig macht und die Prüfung auf einen
sauberen Baum sonst nie erfüllbar wäre.

Ein Fehlerbericht sollte beide Zahlen nennen. Die Fassung allein sagt bei einem
selbst gebauten Stand nicht, was wirklich läuft.

## Tags

Die macOS-App bekommt `v1.4.0`. Käme eine Windows-Fassung, bekäme sie
`win-v1.0.0`, und nichts müsste umbenannt werden. `VERSION` liegt je App unter
`macos/`, weil die beiden nicht im Gleichschritt erscheinen werden.
