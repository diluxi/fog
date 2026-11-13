# where torrents are said to be what no name says well enough (lemma/odos.nix).
# numbers are tmdb's: themoviedb.org/tv/<show>/season/<n> for a show's
# episodes, themoviedb.org/movie/<film> for a film
{
	odos.rules = let
		monogatari = 46195;
		arc = dir: episodes: {
			name = "Monogatari Series/${dir}";
			value = { show = monogatari; inherit episodes; };
		};
	in builtins.listToAttrs [
		# the arcs are seasons 1 to 4 and the extras (0) of one show at tmdb.
		# bakemonogatari's last three are web episodes, which tmdb keeps with
		# the extras
		(arc "01. Bakemonogatari" [
			{ to = 12; season = 1; }
			{ from = 13; season = 0; offset = -11; }
		])
		(arc "03. Nisemonogatari" [ { season = 2; } ])
		(arc "04. Nekomonogatari (Kuro)" [ { season = 0; offset = 5; } ])
		(arc "05. Nekomonogatari (Shiro)" [ { season = 3; } ])
		(arc "06. Kabukimonogatari" [ { season = 3; offset = 5; } ])
		(arc "07. Hanamonogatari" [ { season = 0; offset = 12; } ])
		(arc "08. Otorimonogatari" [ { season = 3; offset = 9; } ])
		(arc "09. Onimonogatari" [ { season = 3; offset = 13; } ])
		(arc "10. Koimonogatari" [ { season = 3; offset = 17; } ])
		(arc "11. Tsukimonogatari" [ { season = 0; offset = 17; } ])
		(arc "12. Koyomimonogatari" [ { season = 0; offset = 21; } ])
		# tmdb makes the two halves of the first, hour-long episode one: they
		# are its two parts, which jellyfin plays as one episode
		(arc "13. Owarimonogatari" [
			{ to = 2; season = 4; parts = true; }
			{ from = 3; season = 4; offset = -1; }
		])
		(arc "14. Owarimonogatari 2nd Season" [ { season = 0; offset = 34; } ])
		(arc "15. Zoku Owarimonogatari" [ { season = 0; offset = 41; } ])
	] // {
		# kizumonogatari is three films
		"Monogatari Series/02. Kizumonogatari/Kizumonogatari I - Tekketsu-hen.mkv".film = 357786;
		"Monogatari Series/02. Kizumonogatari/Kizumonogatari II - Nekketsu-hen.mkv".film = 362584;
		"Monogatari Series/02. Kizumonogatari/Kizumonogatari III - Reiketsu-hen.mkv".film = 362585;
		# a film, which breeze numbers as the series' third special
		"[Breeze] Made in Abyss S00E03 v2 Dawn of the Deep Soul [1080p BD AV1][dual audio].mkv".film = 573730;
	};
}
