# SmartForexBot — MetaTrader 5 / MQL5

Osnovni Expert Advisor za **EURUSD H1**, namenjen izključno demo računu in Strategy Testerju. Na dejanskem računu `OnInit` vrne `INIT_FAILED`; pred naročili ponovno preveri tip računa. Ne uporablja Pythona, zunanjih API-jev ali dodatnih knjižnic.

## Namestitev

1. V MT5 izberi **File → Open Data Folder** in kopiraj `SmartForexBot.mq5` v `MQL5/Experts/SmartForexBot/`.
2. Odpri datoteko v MetaEditorju in pritisni **F7 (Compile)**. Pred uporabo odpravi vse morebitne napake in preveri opozorila.
3. V MT5 osveži Navigator → Expert Advisors. Na **demo računu** odpri graf EURUSD in časovni okvir **H1**, nato pripni EA.
4. Če broker uporablja pripono (npr. `EURUSD.a`), nastavi `InpSymbol` na točno ime grafa. EA preveri, da sta osnovna valuta EUR in kotirana valuta USD.
5. Omogoči Algo Trading v terminalu in dovoljenje za trgovanje v lastnostih EA. Uporabi samo **eno instanco EA na simbol**. Isti simbol naj ne uporablja drugih robotov ali ročnih poslov, zlasti na netting računu.
6. Dnevnik spremljaj v zavihkih **Experts / Journal**, v testerju tudi **Journal**. Posli vsebujejo identifikator, smer, količino, ceno, dobiček, provizijo, swap in fee; naročila beležijo brokerjev retcode.

## Strategija

Na začetku nove H1 sveče primerja EMA na svečah 2 in 1 (obe sta zaključeni). BUY: EMA 20 prečka EMA 50 navzgor; SELL: prečka navzdol. ATR 14 prav tako bere iz sveče 1. Po pripenjanju počaka na novo svečo; ne odpira pozicije za že pretekli signal. Na posamezni sveči naredi največ en poskus vstopa. Preskočenega ali zavrnjenega signala ne ponavlja.

Začetni SL je 1,5 × ATR, TP 2 × ATR od trenutne vstopne kotacije. Če broker zahteva večjo razdaljo, jo EA poveča in cene zaokroži na tick size. Stop razdaljo preverja glede na izstopno kotacijo (Bid pri BUY, Ask pri SELL). SL in TP pošlje skupaj z naročilom; nikoli ne odpira brez njiju kot nadomestnega postopka. Ni trailing stopa, obrata ob nasprotnem signalu, martingala, grida ali dodajanja pozicij. Obstoječa pozicija ostane do SL/TP oziroma dnevnega izstopa.

Pred vstopom upošteva vse pozicije in aktivna naročila na simbolu, tudi ročne in drugih robotov. Kadar je simbol zaseden, vstop preskoči. Preveri način trgovanja, podporo market/SL/TP, način izvršitve FOK/IOC/RETURN, spread, najmanjšo/največjo količino, volume step, stops/freeze level ter kritje. `OrderCheck` opravi končno preverjanje pred `OrderSend`. Po nejasnem rezultatu pošiljanja ne ponavlja vstopnega naročila.

## Tveganje in dnevna omejitev

Osnova za tveganje je manjša od vrednosti **equity in balance**. `OrderCalcProfit` izračuna izgubo do SL v valuti računa, pri čemer vstop premakne še za dovoljeni neugodni odklon. Količino zaokroži navzdol in ponovno preveri izgubo. Če najmanjši lot presega proračun, posel izpusti. Uporabi tudi manjši preostali dnevni proračun ter privzeto 10 % tega proračuna pusti kot rezervo za stroške. `OrderCalcMargin` omeji velikost na največ 95 % prostega kritja; nato sledi `OrderCheck`.

**0,5 % je zgornja meja modeliranega proračuna, ne jamstvo dejanske največje izgube.** `OrderCalcProfit` ne vključuje provizij in swapov. Rezerva ne zagotavlja njihovega pokritja. Vrzel v ceni, drsenje ob zapiranju ali tržna izvršitev lahko povzročijo večjo izgubo; `deviation` pri nekaterih načinih izvršitve ni trda meja. Stop Loss ne jamči izvršitvene cene.

Dnevna omejitev je padec **celotnega equity računa** za 2 % od dnevne osnove in vključuje realizirani ter plavajoči rezultat, stroške in druge posle. Osnova nastane ob prvem ticku novega dne po času brokerja oziroma ob prvi aktivaciji EA tisti dan. **Ob prvi aktivaciji sredi dneva ne rekonstruira prejšnjih izgub.** Nakazila in dvigi vplivajo na ta izračun; med testiranjem jih ne izvajaj.

Ko prag doseže, zaklene nove vstope do naslednjega dne in privzeto poskusi zapreti pozicije tega simbola z njegovim magic ID. Ne zapira poslov drugih robotov ali ročnih poslov; na netting računu ne mešaj lastništva pozicij. Ob neuspelem zapiranju ponovno poskusi na naslednjem ticku. Izstop zaradi omejitve ni blokiran s filtrom spreada. Izguba lahko prag preseže zaradi vrzeli, stroškov, drugih pozicij ali nedostopnega trgovanja. Če `InpCloseOnDailyLimit=false`, samo blokira vstope in obstoječih pozicij ne zapira.

Dnevno osnovo in zaklep shrani v globalne spremenljivke terminala `SFB.<login>.<server hash>.<datum>.*` ter jih obnovi po ponovnem zagonu. Ne briši jih in ne zaženi drugega terminala za obhod omejitve. Stanje je skupno instancam znotraj istega terminala, ne med različnimi terminali. Tester uporablja ločeno stanje v pomnilniku za vsak test. Omejitev se preverja ob tickih EURUSD, ne med izklopljenim terminalom ali brez kotacij.

## Parametri

| Input | Privzeto | Pomen |
|---|---:|---|
| `InpSymbol` | EURUSD | Točno ime brokerjevega simbola |
| `InpTimeframe` | H1 | Prva različica zavrne druge časovne okvire; tudi graf mora biti H1 |
| `InpFastEMA`, `InpSlowEMA` | 20, 50 | Periodi EMA; počasna mora biti večja |
| `InpATRPeriod` | 14 | Perioda ATR |
| `InpSLATR`, `InpTPATR` | 1.5, 2.0 | Množilnika ATR |
| `InpRiskPercent` | 0.5 | Odstotek tveganja; dovoljeno > 0 in ≤ 0,5 |
| `InpCostReservePercent` | 10 | Delež proračuna za rezervo za stroške; 0 do < 100 |
| `InpDailyLossPercent` | 2 | Dnevni prag; dovoljeno > 0 in ≤ 2 |
| `InpMaxSpreadPoints` | 20 | Največji spread za vstop, v točkah |
| `InpDeviationPoints` | 10 | Dovoljeni odklon za naročila, v točkah |
| `InpMagic` | 205014 | Neničeln identifikator EA |
| `InpCloseOnDailyLimit` | true | Ob dnevnem zaklepu zapira lastne pozicije |

Pri petmestnem EURUSD je 10 točk = 1 pip; pri štirimestnem simbolu se pomen točke razlikuje. Nastavitve prilagodi kotaciji in stroškom brokerja.

## Preverjanje in testiranje

**V tem okolju MetaEditor/MT5 prevajalnik ni na voljo. Koda je statično pregledana, ni pa potrjeno uspešno prevedena ali izvedena v MT5. Backtest ni bil opravljen.** Repozitorij nima avtomatske testne zbirke. Preverjanje besedila ne nadomesti prevajanja in testiranja naročil.

Pred uporabo opravi:

1. Prevajanje v MetaEditorju; preveri nič napak in preglej opozorila.
2. Strategy Tester: EURUSD, H1, **Every tick based on real ticks**, realističen začetni kapital, brokerjev leverage, provizije, swap in spread. Preveri obe smeri ter dejanske SL/TP in količine v poročilu.
3. Visual test: preveri prečkanja iz sveč 2/1 in največ en poskus na svečo. Med odprto pozicijo novi signali ne smejo dodajati poslov.
4. Robni primeri: kapital, pri katerem najmanjši lot presega proračun; visok spread; nizko kritje; brokerjeva večja minimalna stop razdalja; EURUSD s pripono; netting in hedging. Pri blokiranem pogoju pričakuj izpuščen vstop, brez povečanja lota.
5. Dnevna omejitev: v testerju začasno znižaj prag, preveri zapiranje in zaklep ter ponovno dovoljen vstop naslednji brokerjev dan. Na demo preveri obstoj zaklepa po ponovnem pripenjanju EA/ponovnem zagonu terminala. Testiraj tudi izklop Algo Trading in zavrnjena naročila.
6. Ločena obdobja za razvoj in preverjanje, več tržnih režimov ter nadaljnji demo forward test. Spremljaj neto pričakovano vrednost, profit factor, največji drawdown, število poslov in občutljivost na stroške. Pri drugih pogojih ponovno preveri rezultate.

Cilj je dolgoročno pozitiven rezultat po stroških, vendar ga ta osnovna strategija **ne zagotavlja**. Želenih 70 % dobičkonosnih poslov ni potrjen rezultat ali obljuba. Visoka uspešnost sama ne pomeni dobičkonosnosti; ne optimiziraj parametrov samo za ta odstotek ali eno zgodovinsko obdobje. Razširitev na druge pare sledi šele po preverjanju te različice.
