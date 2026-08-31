## Download
[here](https://toffeeshare.com/c/Ie-KUoc1Qk)

## steps after download:
1.extract the zip file
2.open the .dmg and move matix the math club into applications
3.ur done!

## if you find any errors
just google it!

---

## app.html lives in the project root

`app.html` in the root of this project is the **single source of truth** for the
whole web app. Edit only that file.

The shell actually loads it from `Matix the Math Club/app.html`, so after editing the root file run:

```
node sync-app.js
```

### Startup order

1. **Loading screen** - dark, dotted grid, neon-green progress bar
2. **Welcome screen** - Google Labs style landing page
3. **Sign in** - only after the user taps "Try it now"

### Editing the landing copy

Sign in as an owner, then use **Edit this screen (owner)** on the welcome screen
(or the pencil button, bottom-right). Everything - wordmark, headline, cards,
category pills, social links - is saved to `/siteContent/gate` and applies for
everyone. No rebuild needed.
