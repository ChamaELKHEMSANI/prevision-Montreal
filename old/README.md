# Documents remplaces

Ce dossier conserve les versions anterieures de documents que le depot a depuis
remplacees. Elles ne decrivent plus l'etat du code et ne doivent pas servir de
reference : elles sont gardees pour la trace.

## `Guide_utilisateur.pdf`

Export Google Docs d'origine du guide utilisateur, ajoute au depot le 19 aout 2026.
Sa source `.docx` — `AirTrafficForecaster_Guide_utilisateur.docx`, d'apres ses propres
metadonnees — n'a jamais ete versionnee et ne se trouve pas non plus sur le Drive du
projet. C'est ce qui a motive sa transcription en Markdown.

Ce PDF decrit une version anterieure de l'application. Entre autres :

- il presente `kenza_probabilistic` comme disponible, et le RECOMMANDE pour quantifier
  l'incertitude, alors que le modele n'est pas enregistre dans le registre ;
- il annonce un export Excel multi-onglets et un rapport PDF de sept pages, alors que
  l'interface ecrit une seule feuille et le graphique seul ;
- il decrit un nettoyage automatique des donnees — imputation par la mediane, ecretage
  a 1,5 IQR, suppression des doublons — qu'aucun appelant ne declenche ;
- il emploie les anciens noms de parametres : `full_penetration`, `full_price_scale`,
  `k1`, `k2` ;
- sa procedure d'installation ne fonctionne pas : mauvaise URL de depot, et
  `Pkg.activate(".")` depuis la racine ouvre un environnement vide, l'environnement
  Julia se trouvant dans `julia/`.

La reference est desormais [`../docs/Guide_utilisateur.md`](../docs/Guide_utilisateur.md),
dont [`../docs/Guide_utilisateur.pdf`](../docs/Guide_utilisateur.pdf) est la mise en page.
