# SmartForexBot v1.1 — MetaTrader 5 / MQL5

Expert Advisor za **EURUSD H1**, namenjen izključno demo računu in Strategy Testerju. Na dejanskem računu `OnInit` vrne `INIT_FAILED`; pred naročili ponovno preveri tip računa. Uporablja MQL5 in vgrajene funkcije MT5, brez Pythona ali zunanjih API-jev.

Različica v1.1 doda izbirni **ADX(14) > 20** filter na zaključeni sveči, dnevnik odločitev ob EMA signalih in privzeto tveganje **0,25 %**. EMA 20/50, ATR 14 ter SL 1,5 × ATR in TP 2 × ATR ostajajo enaki. Filter je hipoteza za preverjanje, ne potrjena izboljšava donosnosti. Izvorna v1.0 je ohranjena v `versions/SmartForexBot-v1.0.mq5`.

## Namestitev ali posodobitev

1. V MT5 izberi **File → Open Data Folder** in odpri `MQL5/Experts/SmartForexBot/`.
2. V to mapo kopiraj **obe datoteki**: `SmartForexBot.mq5` in `SmartForexBotCore.mqh`. Glavni EA vključuje lokalno datoteko `.mqh`; sama datoteka `.mq5` ni dovolj.
3. V MetaEditorju odpri `SmartForexBot.mq5` in pritisni **F7 (Compile)**. Preveri nič napak in preglej opozorila. Različica v lastnostih EA mora biti `1.10`.
4. V MT5 osveži Navigator → Expert Advisors. Na **demo računu** odpri graf EURUSD **H1** in pripni EA. Pri posodobitvi odstrani staro instanco z grafa, nato pripni novo.
5. Če broker uporablja pripono (npr. `EURUSD.a`), nastavi `InpSymbol` na točno ime grafa. EA preveri osnovno valuto EUR in kotirano valuto USD.
6. Preveri vse inpute: MT5 lahko ohrani stare vrednosti ali uvozi staro datoteko `.set`. Za v1.1 nastavi `InpUseADXFilter=true`, `InpADXPeriod=14`, `InpMinADX=20.0`, `InpRiskPercent=0.25` in `InpLogSignals=true`.
7. Omogoči Algo Trading in dovoljenje za algoritemsko trgovanje v lastnostih EA. Uporabi samo **eno instanco na simbol**. Isti simbol naj ne uporablja drugih robotov ali ročnih poslov, zlasti na netting računu.
8. Dnevnik spremljaj v **Experts / Journal**, v testerju v **Journal**. Za analizo shrani nastavitve, poročilo HTML in dnevnik istega testa.

Za osnovno uporabo niso potrebni `tests/` ali arhivska v1.0. Če želiš preizkusiti arhivsko različico, jo namesti in prevedi kot ločen EA z njenim imenom; ne zaženi obeh različic hkrati na istem demo simbolu.

## Strategija in dnevnik

Ob novi H1 sveči primerja EMA na svečah **2 in 1**, ki sta že zaključeni. BUY nastane, ko hitra EMA prečka počasno navzgor, SELL ob prečkanju navzdol. ATR 14 bere iz sveče 1. Po pripenjanju počaka na novo svečo; ne odpira pozicije za že pretekli signal. Na posamezni sveči naredi največ en poskus vstopa. Preskočenega ali zavrnjenega signala ne ponavlja.

Če je `InpUseADXFilter=true`, mora biti glavna vrednost **ADX(14) iz sveče 1 strogo večja od `InpMinADX`**. Vrednost točno 20 pri privzetem pragu ne zadostuje. ADX meri moč trenda; smer še vedno določa prečkanje EMA. Podatkov trenutne odprte sveče ne uporablja za potrditev vstopa. Če ADX manjka ali je neveljaven, pri vključenem filtru ne dovoli vstopa. Pri `InpUseADXFilter=false` ADX ne sme blokirati osnovnega signala, tudi če podatki ADX niso na voljo.

Pri `InpLogSignals=true` dnevnik ob EMA prečkanju pokaže EMA za sveči 2/1, ADX za svečo 1 oziroma nedostopnost podatka, ATR, spread in razlog za sprejet ali preskočen signal. Ko je izračun mogoče opraviti, doda proračun tveganja, količino ter modelirano izgubo do SL. Pri zgodnji zavrnitvi (npr. ADX ali zaseden simbol) izračun količine ni nujno izveden. Izklop tega inputa utiša podroben dnevnik signalov; pomembne napake, naročila in izvršeni posli se še vedno beležijo. Dnevnik ne izpisuje vrstice za vsak tick ali vsako svečo brez prečkanja.

Začetni SL je 1,5 × ATR, TP 2 × ATR od trenutne vstopne kotacije. Če broker zahteva večjo razdaljo, jo EA poveča in cene zaokroži na tick size. Stop razdaljo preverja glede na izstopno kotacijo (Bid pri BUY, Ask pri SELL). SL in TP pošlje skupaj z naročilom. Ni trailing stopa, obrata ob nasprotnem signalu, martingala, grida ali dodajanja pozicij. Obstoječa pozicija ostane do SL/TP oziroma dnevnega izstopa.

Pred vstopom upošteva vse pozicije in aktivna naročila na simbolu, tudi ročne in drugih robotov. Pri zasedenem simbolu vstop preskoči. Preveri način trgovanja, podporo market/SL/TP, način izvršitve FOK/IOC/RETURN, spread, najmanjšo/največjo količino, volume step, stops/freeze level ter kritje. `OrderCheck` opravi končno preverjanje pred `OrderSend`. Po nejasnem rezultatu pošiljanja vstopnega naročila ne ponavlja. Izvršeni posli beležijo identifikator, smer, količino, ceno, dobiček, provizijo, swap in fee; naročila brokerjev retcode.

## Tveganje in dnevna omejitev

Osnova za tveganje je manjša od vrednosti **equity in balance**. Privzeti proračun je 0,25 % te osnove; parameter dovoljuje največ 0,5 %. `OrderCalcProfit` izračuna izgubo do SL v valuti računa, pri čemer vstop premakne še za dovoljeni neugodni odklon. Količino zaokroži navzdol in ponovno preveri izgubo. Če najmanjši lot presega proračun, posel izpusti. Uporabi tudi manjši preostali dnevni proračun in privzeto 10 % tega proračuna pusti kot rezervo za stroške. `OrderCalcMargin` omeji velikost na največ 95 % prostega kritja, nato sledi `OrderCheck`.

**Odstotek tveganja omejuje modelirani proračun, ne zagotavlja dejanske največje izgube.** `OrderCalcProfit` ne vključuje provizij in swapov. Rezerva ne zagotavlja njunega pokritja. Vrzel v ceni, drsenje ob zapiranju ali tržna izvršitev lahko povzročijo večjo izgubo; `deviation` pri nekaterih načinih izvršitve ni trda meja. Stop Loss ne jamči izvršitvene cene. Nižje tveganje zmanjša izpostavljenost in samo po sebi ne izboljša pričakovanega rezultata strategije.

Dnevna omejitev je padec **celotnega equity računa** za privzeto 2 % od dnevne osnove. Vključuje realizirani in plavajoči rezultat, stroške ter druge posle. Osnova nastane ob prvem ticku novega dne po času brokerja oziroma ob prvi aktivaciji EA tisti dan. **Ob prvi aktivaciji sredi dneva ne rekonstruira prejšnjih izgub.** Nakazila in dvigi vplivajo na izračun; med testiranjem jih ne izvajaj. Dnevni prag ne omejuje skupne izgube skozi več dni.

Ko prag doseže, zaklene nove vstope do naslednjega dne in privzeto poskusi zapreti pozicije tega simbola z njegovim magic ID. Ne zapira drugih poslov; na netting računu ne mešaj lastništva pozicij. Ob neuspelem zapiranju ponovno poskusi na naslednjem ticku. Dnevna zaščita deluje neodvisno od prečkanja EMA ali stanja filtra ADX; izstopa ne blokira filter spreada. Izguba lahko prag preseže zaradi vrzeli, stroškov, drugih pozicij ali nedostopnega trgovanja. Če `InpCloseOnDailyLimit=false`, samo blokira vstope in obstoječih pozicij ne zapira.

Dnevno osnovo in zaklep shrani v globalne spremenljivke terminala `SFB.<login>.<server hash>.<datum>.*` ter jih obnovi po ponovnem zagonu. Ne briši jih za obhod omejitve. Stanje je skupno instancam znotraj istega terminala, ne med različnimi terminali. Tester uporablja ločeno stanje v pomnilniku za vsak test. Omejitev se preverja ob tickih EURUSD, ne med izklopljenim terminalom ali brez kotacij.

## Parametri

| Input | Privzeto | Pomen |
|---|---:|---|
| `InpSymbol` | EURUSD | Točno ime brokerjevega simbola |
| `InpTimeframe` | H1 | V1.1 zahteva H1; tudi graf mora biti H1 |
| `InpFastEMA`, `InpSlowEMA` | 20, 50 | Periodi EMA; počasna mora biti večja |
| `InpATRPeriod` | 14 | Perioda ATR |
| `InpSLATR`, `InpTPATR` | 1.5, 2.0 | Množilnika ATR |
| `InpUseADXFilter` | true | Vstop zahteva ADX nad pragom; false omogoči osnovno EMA različico |
| `InpADXPeriod` | 14 | Perioda ADX |
| `InpMinADX` | 20.0 | Najnižji prag; ADX mora biti strogo večji |
| `InpLogSignals` | true | Podroben dnevnik EMA signalov in razlogov odločitev |
| `InpRiskPercent` | 0.25 | Odstotek tveganja; dovoljeno > 0 in ≤ 0,5 |
| `InpCostReservePercent` | 10 | Delež proračuna za rezervo za stroške; 0 do < 100 |
| `InpDailyLossPercent` | 2 | Dnevni prag; dovoljeno > 0 in ≤ 2 |
| `InpMaxSpreadPoints` | 20 | Največji spread za vstop, v točkah |
| `InpDeviationPoints` | 10 | Dovoljeni odklon za naročila, v točkah |
| `InpMagic` | 205014 | Neničeln identifikator EA |
| `InpCloseOnDailyLimit` | true | Ob dnevnem zaklepu zapira lastne pozicije |

Pri petmestnem EURUSD je 10 točk = 1 pip; pri štirimestnem simbolu se pomen točke razlikuje. Nastavitve prilagodi kotaciji in stroškom brokerja.

## Primerjalni backtest A/B

**V tem okolju MetaEditor/MT5 prevajalnik ni na voljo. V1.1 ni bila tukaj prevedena ali backtestana; uspešno delovanje v MT5 še ni potrjeno.** Uporabnikovo poročilo za v1.0 je pokazalo 489 pozicij in −2.096,62 USD na začetnih 10.000 USD. To ni rezultat v1.1 in ne dokazuje koristi ADX.

1. V MetaEditorju odpri in prevedi glavni `SmartForexBot.mq5`; datoteka `SmartForexBotCore.mqh` mora biti v isti mapi. V Strategy Testerju izberi EURUSD H1, **Every tick based on real ticks**, izklopljeno optimizacijo ter realističen kapital, leverage, spread, provizije in swap nameravanega brokerja.
2. **Test A:** v Strategy Testerju odpri **Inputs → Load** in naloži `presets/SmartForexBot-v1.1-baseline.set`: filter je izključen, tveganje 0,25 %, dnevnik vključen. Po nalaganju preveri `InpSymbol` in ga po potrebi nastavi na brokerjev EURUSD s pripono. Shrani nastavitve, HTML in Journal.
3. **Test B:** naloži `presets/SmartForexBot-v1.1-adx.set`. Datoteki vsebujeta vse inpute in se razlikujeta samo v `InpUseADXFilter=true`; ADX je 14, prag 20. Tudi tukaj preveri oziroma enako popravi simbol s pripono. Kapital, leverage, obdobje, model tickov in stroški niso del `.set`; v obeh testih jih nastavi enako. Shrani ločene rezultate.
4. Primerjaj neto rezultat, profit factor, equity drawdown, število poslov, rezultate po letih in razloge za preskočene signale. Manjši padec ob mnogo manj poslih sam zase še ne dokazuje boljše strategije. Prag 20 določi pred primerjavo in ga ne prilagajaj le zaradi boljšega rezultata te zgodovine.
5. Za primerjavo z arhivsko v1.0 nastavi **iste** stare inpute, vključno s tveganjem 0,25 %. Prvotnega testa pri 0,5 % ne primerjaj neposredno z novim pri 0,25 % kot dokaz učinka ADX. Izklop filtra v v1.1 ohrani osnovna EMA pravila, ne izvornih privzetih vrednosti tveganja ali enakega dnevnika. Ob začasno manjkajočem ATR v1.1 signal zabeleži in preskoči; v1.0 je poskusila podatke znova prebrati znotraj iste sveče. Zato za izolacijo učinka ADX uporabi testa A/B z isto v1.1.
6. Zgodovina 2020–2026 je bila že pregledana. Nadaljnje analize tega obdobja so raziskovalne; ločeno časovno preverjanje oziroma walk-forward in prihodnji demo forward test sta potrebna pred sklepanjem o izboljšanju.

## Ročno preverjanje v MT5

Preizkuse izvajaj v testerju oziroma na namenskem demo računu. Pred vsakim preveri, da so se dogodki dejansko zgodili; odsotnost poslov sama po sebi ne potrdi zaščite.

| Preizkus | Pričakovano vedenje / dokaz |
|---|---|
| Vizualni pregled signala | Prečkanje uporablja sveči 2/1, ATR in ADX svečo 1; ADX točno 20 ali manj blokira vstop pri vključenem filtru. |
| Filter izključen | Osnovni EMA signal ne sme biti zavrnjen zaradi nizkega ali nedostopnega ADX; ostale zaščite veljajo. |
| Premajhen kapital / najmanjši lot | Signal preskoči, kadar najmanjša količina presega proračun; lota ne poveča. Dnevnik pokaže razlog. |
| Visok spread | Znižaj dovoljeni spread za namenski test; pri signalu nad pragom pričakuj preskočen vstop. |
| Izključen Algo Trading | Na demo izklopi dovoljenje in počakaj na EMA signal; naročila ne pošlje in razlog je razviden v dnevniku. |
| Nizko kritje / zavrnitev brokerja | Preveri odsotnost nove pozicije in dnevnik preverjanja kritja ali `OrderCheck`/`OrderSend` s kodo zavrnitve. Ne izklapljaj zaščit za prisilno odpiranje. |
| Dnevni prag | Za namenski test nastavi npr. `InpDailyLossPercent=0.1`; dejansko dosezi padec in preveri zaklep ter poskus zapiranja lastne pozicije. Preveri tudi ob nizkem/izključenem ADX ter brez novega EMA prečkanja. Nato obnovi privzetih **2 %**. |
| Ponovni zagon in nov dan | Na demo po zaklepu ponovno pripni EA oziroma zaženi terminal: isti dan ostane zaklenjen. Preveri tudi novo dnevno osnovo naslednji brokerjev dan. Testerjev pomnilnik se pri novem testu začne znova. |
| En simbol / ena pozicija | Ob odprti poziciji ali aktivnem naročilu na simbolu nov signal ne doda pozicije. |
| Realistična izvršitev | Primerjaj izračunano tveganje v dnevniku z izstopno ceno in stroški. SL ni jamstvo dejanske izgube. |

Prenosni testi čistih odločitev v `SmartForexBotCore.mqh` se lahko zaženejo brez MT5:

```sh
g++ -std=c++17 -Wall -Wextra -Werror tests/test_core.cpp -o /tmp/smartforexbot-core-tests
/tmp/smartforexbot-core-tests
```

Ti testi preverjajo skupne funkcije za signale, mejo ADX in dnevni prag v združljivem C++ okolju. Ne preverjajo MQL5 dogodkov, indikatorjev, brokerjeve izvršitve ali celotnega EA in ne nadomestijo prevajanja v MetaEditorju ter testiranja v MT5.

Cilj je dolgoročno pozitiven rezultat po stroških, vendar ga ta strategija **ne zagotavlja**. Želenih 70 % dobičkonosnih poslov ni potrjen rezultat ali obljuba. Visoka uspešnost sama ne pomeni dobičkonosnosti; ne optimiziraj parametrov samo za ta odstotek ali eno zgodovinsko obdobje. Pravi račun ostaja blokiran. Razširitev na druge pare sledi šele po preverjanju te različice.
