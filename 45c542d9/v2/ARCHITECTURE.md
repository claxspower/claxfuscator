# Clax v2 — Ticari Seviye Lua Obfuscator Mimarisi

Bu belge 12 katmanlı hattın modül sınırlarını, veri akışını, performans
bütçesini ve ölçüm yöntemlerini tanımlar. v1 (`../obfuscator/`) çalışan
referanstır; v2 ayrı hatta kurulur ve modül onaylarıyla ilerler.

## Hedefler ve ölçüm

| Metrik | Hedef | Ölçüm |
| --- | --- | --- |
| Yavaşlama | ≤ 3.0× | 1000 satır benchmark, ham/obf aynı host, 5 koşu medyanı |
| Toplam opcode | ≥ 200 | Üretilen dispatch anahtarı sayısı |
| Decoy oranı | ≥ 2.0× gerçek | decoy / real, build istatistiğinde |
| Polimorfizm | 10/10 farklı SHA256 | Aynı girdi, 10 rastgele seed |
| String sızıntısı | 0 | `strings` + 4+ karakterlik literal taraması |
| Decompile | doğrudan araç yok | luac/luadec/unluac çıktı denemesi |
| Build süresi | < 10 sn / 1000 satır | CLI duvar saati |
| Ek bellek | < 50 MB | `collectgarbage("count")` farkı |

Yavaşlama hedefi bu mimaride yalnız C çağrısı ağırlıklı iş yüklerinde
tutulabilir: saf-Lua dispatch VM'i hesaplama ağırlıklı kodda baskındır. Ölçüm
(2026-11-08, 802 satır / 10 000 fonksiyon çağrısı, native 5.4, 5 koşu min):
ham 2 ms, `strong` 2 265 ms (≈1 130×), `fast` 298 ms (≈150×).
Build 2,4 s ve çıktı 2,35 MB ile bütçe içindedir. Bu sınır risk kaydında ve
M12 raporunda açıkça belirtilir.

## Modüller ve katman eşlemesi

| Modül | Dosya | Katman | Girdi → Çıktı |
| --- | --- | --- | --- |
| M1 | `src/lexer.lua`, `src/parser.lua`, `src/ast.lua` | 1 | kaynak → normalize AST + tanılama |
| M2 | `src/scope.lua` | 2 | AST → sembol tabloları, `_0x` isim planı |
| M3 | `src/flatten.lua` | 3 | AST → state-machine AST |
| M4 | `src/opaque.lua` | 4 | AST → MBA koşul sarmalları |
| M5 | `src/consts.lua` | 5 | AST → gizlenmiş sayı/bool/nil |
| M6 | `src/strings.lua` | 6 | string havuzu → 6 şemalı şifreli blob + VM decoder |
| M7 | `src/compiler.lua` | 7 | AST → register bytecode (80 gerçek opcode) |
| M8 | `src/vmgen.lua` | 7+8 | bytecode → O(1) handler tablosu + decoy dispatch |
| M9 | `src/bytecode.lua` | 9 | bytecode → paketli, şifreli payload + checksum |
| M10 | `src/selfmod.lua` | 10 | bytecode → 4'lük blok zinciri + kendini yeniden şifreleyen blok deposu |
| M11 | `src/antidebug.lua` | 11 | runtime → yükleme probu + sessiz değer sapması |
| M12 | `src/integrity.lua`, `src/obfuscate.lua`, `src/autofix.lua`, `src/emit.lua` | 12 | tüm parçalar → tek Lua dosyası + CLI + doğrulama/onarım |

## Bağımlılık grafiği

```
                 ┌──────────── M1 ────────────┐
                 ▼                            ▼
                M2                        (tanılama)
        ┌────────┼─────────┐
        ▼        ▼         ▼
       M3       M4        M5 ───► M6
        └────────┼─────────┘        │
                 ▼                  │
                M7 ◄────────────────┘
                 ▼
                M7
                 ▼
                M10 ──► M9 (paket)
                 ▼
                M8 ◄── M11, M12
                 ▼
                M12 ───► tek dosya
```

Kurallar:
- M1 yalnız lexer'a bağlıdır; AST sözleşmesi dışında hiçbir modül parser
  iç yapısını görmez.
- M2 tek doğruluk kaynağıdır: isim, kapsam, upvalue ve etiket kararları burada
  verilir. Sonraki modüller program değişkeni adı üretmez; yalnız çakışma
  kontrolünden geçen runtime iskeleti bağlamaları ekler.
- M5 string literallerini M6'ya devreder; M6 şifreli havuzu ve çözücü değerini
  üretir, M7 bu değeri VM proto'suna derler — host Lua'da isimli çözücü kalmaz.
- M7 opcode isimlerini M8'den bağımsız bilir; M8 yalnız sayı eşlemesi ve
  handler üretir.
- M10'un blokları M9'un düz metin akışı içinde taşınır; hiçbir aşamada düz
  komut tablosu yayınlanmaz.
- M11/M12 yalnız M8'in ürettiği runtime iskeletine kod enjekte eder.

## Veri akışı

```
kaynak
  → Lexer (token + tanılama)
  → Parser (kompakt AST, hata kurtarma)
  → Ast.normalize (type/children sözleşmesi)
  → Scope (bağlar, _0x isimleri, upvalue hücreleri)
  → Consts (MBA sabitler; stringler M6'ya)
  → Flatten (blok → state machine)
  → Opaque (MBA koşullar)
  → Strings (6 şemalı şifreli havuz + runtime çözücü)
  → Compiler (80 opcode, register ISA)
  → Bytecode (varint paket + ChaCha20 + 16B checksum)
  → SelfMod (blok zinciri, isteğe bağlı)
  → VMGen (O(1) handler tablosu, 160 decoy, gömülü decoder)
  → AntiDebug + Integrity (sessiz sapma, geç-hook mandalı, SipHash zinciri)
  → Emit (tek dosya, Lua 5.1 alt kümesi)
  → Autofix (kaynak ↔ çıktı çıktı karşılaştırması, seed/ayar merdiveni)
```

`obfuscate.run(source, opts)` tek giriştir (`preset`, `seed`, `decoys`,
`flatten`, `opaque`, `selfmod`, `antidebug`, `integrity`, `schemes`,
`executor`, `gethui`, `antiwebhook`); `emit` yalnız `obfuscate` üzerinden
çağrılır. `executor`/`gethui`/`antiwebhook` varsayılan kapalıdır (nil → off),
preset'ten bağımsız tek tek açılır. `autofix.run` aynı girişi sandbox'ta
doğrular, uyuşmazlıkta ayarları kademeli düşürür.

Executor kapısı (`executor=true`): çıktı yalnız gerçek executor'da çalışır.
Girişte `getgenv` (fonksiyon) veya `game` (DataModel) aranır; website
compiler/runner'larında ikisi de yoktur → sessiz `return`. Kapı isimleri
DM çözücüsüyle şifreli taşınır, düz metin `getgenv`/`game` sızmaz.
`gethui=true`: `gethui` yoksa `CoreGui`'ye düşen bir sarmalayıcı enjekte eder
(pcall korumalı, Roblox dışı host'ta no-op). `antiwebhook=true`:
`http_request`/`request` sarmalanır, URL'sinde `webhook` geçen istekler
düşürülüp `{StatusCode=200,Body=""}` döner; metamethod hook'u kurulmaz.

## Kritik tasarım kararları

### Dispatch (katman 7-8)
Lineer `elseif` yok. Build sırasında `H[op]` fonksiyon tablosu üretilir:

```lua
local H = { [17]=function(I,R,K,U,S,pc) local a,b,c,d=I[2],I[3],I[4],I[5]
  R[a]=K[d] return pc+1 end, ... }
while true do
  local I = code[pc]
  local npc = H[I[1]](I, R, K, U, S, pc)
  if npc == false then return unpack(S.ret, 1, S.ret.n) end
  pc = npc
end
```

- Handler başına tek tablo erişimi + tek çağrı: O(1).
- Polimorfik handler gövdeleri (`VMGen.VARIANTS`): sıcak opcode'lar (MOVE,
  LOADK, ADD/SUB/MUL/DIV, ADDK/ADDI, NOT/LEN, EQ/NE/LT/LE, GETGLOBAL,
  GETFIELD/GETTABLE) için build başına rastgele seçilen eşdeğer gövde
  şablonları. Her varyant aynı operatör/operand sırasını korur (metamethod
  dispatch değişmez); `NOT` varyantı `(R[b]==nil or R[b]==false)` kullanır
  (nil/false karşılaştırması `__eq` çağırmaz, `not R[b]` ile birebir).
  Aynı seed aynı varyantı seçer; farklı seed'ler aynı opcode'u farklı gövdeyle
  yayar, böylece handler imza taraması tek bir kalıba tutunamaz.
- İkinci varyant grubu (`VMGen.EXTRA_VARIANTS2`): MOVE/LOADK, tablo ve global
  erişimleri, aritmetik/karşılaştırma, JMP/JMPF/JMPT, TEST ve TESTSET gövdeleri
  de build başına eşdeğer biçimlerden seçilir; böylece aynı opcode bir
  prototipte iki kez geçse bile gövde şekli tekrar etmez. `TEST` varyantı
  `pc+2` koşulunu doğru dalda tutar (ters yazımı VM'i sessizce bozuyordu;
  kabul testi ham test atlamasını bu yüzden çalıştırır).
- 80 gerçek opcode × 14 encoding = 1 120 gerçek anahtar, artı build başına
  decoy (varsayılan 448, preset'ler 512/320/160, üst sınır 1024). Tüm
  handler'lar aynı imzayı taşır, ama altı parametrenin sırası build başına
  permüte edilir: çağrı yeri ve her handler aynı karışık listeden üretilir,
  böylece dump edilen bir imza pozisyonel olarak
  `(I,R,K,U,S,pc)` diye çözülemez.
- Decoy gövdeleri sabit dönüş değil: literal şablon havuzu (135 gövde) artı
  build başına üretilen sentez decoy'lar (asla sağlanmayan yüklem × gerçek
  handler sözlüğünden kamuflaj aksiyonu × koşulsuz dönüş). Her handler ve
  decoy gövdesi ayrıca rastgele bir zarfla sarılır (`do`, `if pc>0`,
  `repeat…until true`, çift `do`), yani aynı opcode iki build'de yalnız isim
  değil ifade yapısıyla da ayrışır.
- `S` çerçeve tablosudur: hareketli `top`, çalışan proto, paketlenmiş argümanlar
  ve kuyruk dönüşü (`S.ret`). `RETURN`/`TAILCALL` `false` sentinel'i döndürür;
  dispatcher sonuçları tek yerden açar.
- Kontrol handler'ları `pc±1+d` döndürür; diğerleri `pc+1`.
- 3× bütçesi için ikinci aşama: sık opcode çiftleri süper-komut olarak
  birleştirilir (M12 benchmark'ında ölçülür).

### Opcode uzayı (katman 8)
- Anahtarlar 1..65535 aralığında permüte edilir; her build'de yeni permütasyon.
- Gerçek 80×14 = 1 120 anahtar, decoy varsayılan 448 (preset 512/320/160),
  `opts.decoys` 0..1024 arası. Decoy'lar hiçbir zaman üretilmez, yalnız
  tabloda bulunur; dump eden araç gerçek/decoy ayrımını çalışmadan yapamaz.
- Her opcode'un on dört encoding'i kendi anahtarını, slot permütasyonunu ve
  sign/bias maskesini taşır; altı yasal slot düzeni (immediate slot 5'te
  sabit) dönüşümlü dağıtılır. Bir talimatı çözen analiz, tablonun 1/1120'sini
  öğrenmiş olur.
- Decoy literal havuzu (135 gövde) + build başına sentez decoy + rastgele
  gövde zarfları; handler tablosu sırası da build başına karıştırılır.

### Bytecode (katman 9)
- `{op,a,b,c,d}` beşlileri varint olarak paketlenir, tek byte string olur.
- İlk 16 byte: FNV-1a tabanlı checksum + sürüm etiketi.
- Gövde: 64 baytlık bloklara sıfırla doldurulup ChaCha20 sayaç modunda
  şifrelenir (RFC 8439 tur yapısı, yalnız aritmetik: 5.1'de bit operatörü
  yok). Anahtar oturum anahtarıdır (gömülü anahtar + dolgulu gövde uzunluğu),
  8 anahtar kelime LCG ile açılır; üç nonce kelimesi oturum anahtarı etiketini,
  gerçek uzunluğu ve dolgulu uzunluğu bağlar.
- VM açılışta çözer, `code` tablosunu kurar; iş bitince `R`, `K`, `code`
  referansları nil'lenir.
- Sabit havuzu ikinci kez, prototip başına ayrı durumla şifrelenir
  (`constCrypt`): her prototipin `K` bölümü `FNV-1a` etiketi + zincirli LCG
  akışıyla mühürlenir ve anahtar `(key, proto index, uzunluk)`'tan türetilir.
  Her maske bir önceki **şifreli** baytı zincire katar, yani tek konumdaki
  seçilmiş düz metin sınaması akışın başka yerini açığa çıkarmaz. Çözücü
  bölümü ilk sabit okumasında açar: dump, programın gerçekten dokunduğu
  havuzları görür, çağrılmamış fonksiyonların sabitleri şifreli kalır.

### Self-modifying bytecode (katman 10)
- Her blok ayrı anahtarla şifrelenir; blok anahtarı önceki blok anahtarından
  türetilir (zincir).
- N komutta bir sonraki blok çözülür; canlı pencere `min(total, 256)` komuttur.
  Pencere dolunca en eski blok yeni durumla yerinde yeniden şifrelenip düşürülür.
- Statik dump yanlış blokları görür; ölçülen selfmod ek yükü ≤ ~%6
  (2 000 çağrı: 37 ms vs 35 ms), yalnız `strong`.

### Anti-debug (katman 11)
- Yükleme anında **otuz üç prob**, hepsi `pcall` içinde ve salt okunur;
  hiçbiri hata üretmez, hook kurmaz, `debug` tablosunu yazmaz:
  etkin hook (`debug.gethook`), taze fonksiyonun `what=="Lua"` ve
  `linedefined>=0` raporu, `debug.getinfo(fn,"f")` özdeşliği, iki çağrıda
  kararlı ve boş olmayan `string.dump`, `string.byte`/`concat`/`pcall`/
  `select` bütünlüğü, **global `type` bütünlüğü** (primitive'ler için doğru
  sınıf adı; sarılmış/monkeypatch'lenmiş `type` tetikler), **reload probu**
  (anti-dump), **`xpcall` çoklu dönüş + hata yönlendirme probu** (3,4 dönüşü
  ve hata değerinin handler'a aynen geçmesi; sarmalanmış/yer değiştirmiş
  `xpcall` tetikler), **desen motoru probu** (`gsub` callback'i iki rakam
  için iki kez çağrılmalı, `gmatch` sayısı 2; yakalanmış desen motoru
  tetikler), **coroutine probu** (yield 4→5 suspended, resume 6→12 dead,
  `wrap` 7→8; kotoutine durumlarını yanlış raporlayan hata ayıklayıcı
  tetikler) ve **kaynak bilgisi probu** (`getinfo(fn,"S")` iki fonksiyon
  için tablo, `source` string ve aynı, `linedefined>=0`, `short_src`
  string; kaynak izlerini silen dump/deobf harness'ı tetikler), **uzunluk/
  paket probu** (`#t` ve `unpack`/`table.unpack` dönüş sayısı; uzunluk
  operatörünü veya `unpack`'i sarmalayan host tetikler), **metatable probu**
  (`__index` tablosu üzerinden alan okuması ve `getmetatable` özdeşliği;
  referans da tablo kullanır, çünkü metin `__index` geçersiz Lua'dır ve temiz
  host'u yanlış işaretler) ve **gc probu** (`collectgarbage("count")` sayı ve
  monoton; sayacı donduran instrumentation tetikler).
- Prob şekli sağlaması (`ADN`): her build'de tohumdan türetilen bir token
  (`(i*97+seed%251)%401+7`) her prob bloğunun başına `ADN=ADN+tok` olarak
  eklenir; prolog sonunda `ADN` beklenen toplama eşit değilse `ADT` eşik
  kadar artırılır. Bir prob bloğunu silmek, sırasını değiştirmek veya
  gövdesini yamalamak toplamı bozar; yama "başarılı" görünse bile sapma
  sessizce devreye girer. Token listesi ve toplam sabit değildir, her
  seed'de değişir.
- Reload probu: bir upvalue (`uv`) yakalayan closure kurulur, `load`/
  `loadstring` ile taze bir fonksiyon derlenip aynı upvalue'yu okuması
  beklenir; dump eden araç closure'ı yeniden yüklediğinde upvalue hayatta
  kalır (`v == uv`) ve prob tetiklenir. Reload biti her build'de zorla açık
  tutulur (bit konumu isimle aranır, prob listesi büyüse de kaymaz) ve ağırlığı
  2'dir (eşik 2): tek başına dump'i yakalar.
- Hook probu ağırlık 2 taşır ve eşik 2'dir: canlı hook tek başına eşiği geçer,
  tek zayıf prob geçmez. Zayıf prob seçimi, ağırlıkları (1-2) ve sırası build
  seed'inden türetilir; `Antidebug.probe` aynı kararı build tarafında yansıtır.
- Eşik aşılırsa hata/çıkış yok: her değer string sabitinin harfleri yerinde
  döndürülür (büyük/küçük korunur, z→a, A→Z). Sayılar, bool/nil, global ve
  alan adları dokunulmaz; komut akışı bozulmaz, oturum yanlış veriyle sessizce
  sürer. Korunan sabit listesi M7 komutlarından türetilir: yalnız `LOADK` ile
  yüklenen ve `GETGLOBAL`/`SETGLOBAL`/`GETFIELD`/`SETFIELD`/`SELF` anahtarı
  olmayan string'ler.
- Giriş çağrısı tüm hataları yutan bir `pcall` zarfındadır; bozulan veri bir
  hata üretse bile dışarı sızmaz.
- Geç hook kilidi: yükleme problarından sonra kurulan izleme hook'u ayrı bir
  iki-vuruş mandalıyla (`ADH`) yakalanır. Mandal yalnız `ADT==0` (yükleme
  sapması yok) **ve** `ADE==0` (executor değil) iken ilerler; `gethook()` nil
  dönerse sıfırlanır. İki ardışık vuruş M12 tick'inde `ADH>=2` koşuluna dönüşür
  ve normal nil-index hatasını üretir. Autofix sandbox'ı ve hook'suz host'lar
  `gethook()` nil aldığı için asla yanlış pozitif üretmez.

### Ortam gürültüsü ve yükleme-sonrası ilkel fotoğrafı (M11/M12)
- Ortam gürültüsü: gerçek yakalamaların iki yanına, tohumdan seçilen **25
  sahte okuma** serpiştirilir (Roblox servisleri, executor yardımcıları,
  `debug`/`string`/`io` alanları). Hepsi tek bir `CH` tablosuna yazılır, isimler
  bayt kodlu `DM` ile üretilir ve `pcall` zarfındadır; hiçbir şey çalışmaz,
  yalnız okunur. Bir env logger'ın "gerçekten kullanılan global" listesini
  gürültüden ayırması mekanik olmaktan çıkar; okuma grubu iki karışık blok
  hâlinde gerçek yakalamaların önüne ve arkasına düştüğü için "ilk N okuma
  kurulumdur" sınırı da yoktur.
- Yükleme-sonrası ilkel fotoğrafı: `debug.gethook/getinfo/getupvalue/
  getregistry`, `string.dump`, `load`, `loadstring` kimlikleri yükleme biterken
  `IS` tablosuna alınır, ardından **28 ek giriş** aynı tabloya eklenir
  (`debug.traceback/getlocal/setlocal/setupvalue`, `coroutine.*`,
  `set/getmetatable`, `rawget/rawset`, `xpcall`, `select`, `tonumber`,
  `tostring`, `next`, `pairs`, `ipairs`, `error`, `string.char/byte/sub/find/
  gsub`, `table.concat`, `math.floor`). M12 tick'i bu **35 girişi** her
  kontrolde yeniden karşılaştırır (yalnız yüklemede var olan girişler;
  Luau/sandbox'ta eksik alan nil kalır ve atlanır) ve script çalışırken
  bunlardan birini değiştiren dump/devirt harness'ini normal nil-index
  hatasına düşürür. 7'li çekirdek her hostta çalışır; 28 ek kontrol
  `(not ADE)` koşuluna bağlıdır, yani executor ortamında (`getgenv` vb.)
  hiç değerlendirilmez — yardımcı kütüphaneleri sarmalayan sağlıklı bir
  executor yanlış pozitif üretmez, düz host'ta ise sarılmış tek bir ilkel
  yakalanır. Karşılaştırma `cfg.extra` üzerinden zincir denetimine `or`
  terimi olarak eklenir; sıcak yolda ek maliyet yoktur.

### Compact çıktı mührü (web driver)
- Sorun: compact motor kaynak-kaynak bir yayıcıdır; çıktısı okunabilir bir VM
  gövdesidir (`local ...` ve `end` satırları). Dosyayı dökümleyen biri, programı
  VM talimat düzeyinde okuyabiliyordu. Mühür, `compactBuild`'in son adımıdır ve
  yalnız çıktıyı değil yapıyı da saklar.
- Boru hattı artık **blokludur**: gövde 131 072 baytlık dilimlere ayrılır,
  her dilim ayrı ayrı **LZSS** ile paketlenir (2 048 penceresi, 11 bit mesafe,
  4 bit uzunluk, 3..18 eşleşme; 8 baytlık başlık: 4 bayt LE özgün uzunluk —
  yüksek bit `SEAL_RAW_BIT` = 8 388 608 sıkıştırılmadı demek — ve 4 bayt
  dilimin FNV-32 özeti). 2 MiB üstünde LZSS atlanır (zaten sıkışmayan VM
  çıktısında kazanç düşük, maliyet yüksek), dilim ham olarak başlığa yazılır.
  Her dilim kendi konum-bağımlı akış şifresiyle şifrelenir, ardından
  **13 bit/çift** base91 ile 91 sembollü alfabeye çevrilip ayrı bir
  `bl={[==[...]==],...}` alanına gömülür. Alfabe yazdırılabilir ASCII
  33..126'dan `"`, `\`, `]` çıkarılarak kurulur ve tohumla karıştırılır;
  böylece blob `[==[ ]==]` içinde kaçışsız durur ve çıktı saf ASCII kalır
  (`£ ½ é` gibi semboller bu kuralı bozardı). Kuyruk her zaman tam çift
  olduğundan çözücü tek sembol artığıyla uğraşmaz. Bloklama sayesinde mühür
  boyuttan bağımsızdır: 34 KB'lık girdi 12 blok, 360 KB'lık girdi bölünmüş
  build'in her parçasında ayrı bloklar üretir.
- Çıktı `return setmetatable({},{__call=function(P,...)` ile başlar; blob,
  alfabe ve anahtar `__call` içinde `P` alanlarına atanır, dışarıya verilen
  tablo **boştur** (ortam günlükleri çağrı argümanlarını kaydettiği için
  serileştirecek bir şey kalmaz). `__call` gövdesi tek satırlık bir **durum
  makinesidir**: her aşama tohumdan seçilmiş sayısal bir anahtarla tek bir
  dispatch tablosunda yaşar, her aşama bir sonraki durumu döndürür, gövdedeki
  tek döngü `while <durum> do <durum>=<tablo>[<durum>](P) end` biçimindedir.
  Aşama sırası, durum numaraları, alan adları ve 55 rolün her birinin kimliği
  build başına yeniden üretilir; tabloda hiçbir zaman çalışmayan iki decoy
  döngüsü de bulunur. **Çıktıda tek bir `local` yoktur**: tüm durum `__call`
  parametresinin (`P`) alanlarında yaşar, aşamalar değer döndürür; chunk
  yalnız `return setmetatable(...)(...)` ve aşama içi `return <durum>`
  zincirlerinden oluşur. Blob'un arkasına hedef 11.8–16 KB'a tamamlayacak
  kadar alfabe sembolü eklenir; çözücü uzunluk başlığında durduğu için dolgu
  yükten ayırt edilemez.
- Şifre: her blok **konum-bağımlı** bir akış şifresiyle açılır. Durum blok
  başına `s=(2166136261+(bi-1)*2654435761)%2^32` ile kurulur ve
  `s=(s*1664525+kk*131+i+(bi-1)*65537)%2^32` ile ilerler; anahtar dilimi
  `((i-1)*mul+(bi-1)*8)%16+1` ile seçilir, yani aynı anahtar 16 baytta bir
  döner ama her blokta 8 konum kayar. `kk` anahtar dizesinin build-tohumlu
  permütasyonla seçilen 16 sembolünden biridir, `i` bayt sırasıdır. Anahtar
  akışının üst ya da alt baytı tohumla seçilir, her düz bayt bir öncekine
  zincirlenir (CBC benzeri) ve sonuç 16×16 nibble XOR tablosundan geçer.
  Blok kimliği hem başlangıç durumuna hem de anahtar akışına girdiği için
  bir blok diğerinin yerine taşınamaz; aynı blob'u farklı konumdan başlatmak
  çıktıyı tamamen bozar; anahtar da sayı tablosu değil alfabe sembollerinden
  oluşan bir dize olarak durur. Kodlayıcı ve çözücü terimleri birebir
  eşleşmezse build zaten doğrulamada düşer (bu turda iki terim eşitsizliği
  bu şekilde yakalandı ve düzeltildi).
- Bütünlük: her dilimin 8 baytlık başlığı (4 bayt uzunluk — yüksek bit ham
  işareti — ve 4 bayt **dilimin FNV-32 özeti**) çözücü tarafından yeniden
  hesaplanır ve karşılaştırılır; tutmazsa normal nil-index hatası verilir.
  Uzunluk ile checksum birbirinden bağımsız olduğu için tek sembollük bir
  kurcalama sessiz yanlış çıktı yerine hata üretir. Dilim sayısı da denetlenir
  (`#bl<1` ayrıca hata verir).
- Çözücü 16×16 nibble XOR tablosunu özyinelemeli bir `xor` fonksiyonuyla
  kurar (tablo döngüleri ve `local` yok), blokları **sırayla** base91'den
  çözer, şifresini açar, LZSS'i 512 baytlık parçalar hâlinde string'e çevirir
  ve blok metinlerini `concat` edip `load` ile derler. Bellekte aynı anda tek
  dilim bulunur; 12 bloklu 34 KB'lık örnekte bile tepe bellek iki katına
  çıkmaz. Ortam `_ENV` → `load(Z,"=s","t",env)`; Luau'da `loadstring`;
  5.1'de `loadstring` + `setfenv(...,_G)`. Fonksiyon üretilemezse normal
  nil-index hatası verilir; çıktı hiçbir katman adı taşımaz.
- Döküm/ortam güçlendirmesi: çözücü bütün kütüphaneleri **tek bir ortam
  tutamağından** (`_G`, 5.2+ için `_ENV`) bayt kodlarıyla kurulmuş adlarla
  okur (`string`, `table`, `math`, `type`, `select`, `pcall`, `setfenv`,
  `loadstring`, `load`), her biri için düz global yedek bırakır. Hiçbir yerde
  `getfenv` **çağrılmaz**: Dex benzeri bir ortam günlüğünde çözücüden geriye
  yalnız boş `setmetatable` çağrısı kalır. `dump`, `gethook`, `debug`, `min`,
  `concat` gibi üyeler çalışma anında bayt kodlarından kurulur, bu yüzden
  dosyada bu kelimeler geçmez. Luau iki ayrı yolla tanınır (`_VERSION` dizesi
  — `"Luau"` değeri de bayt kodlarından kurulur — ve yalnız Luau'da bulunan
  `table.clone`), böylece `_VERSION`'ın eksik olduğu
  bir executor eski 5.1 dalına düşemez. Yükleme öncesi `string.dump` ve
  `debug.gethook` kimlikleri alınır, `load`'dan hemen sonra yeniden
  doğrulanır; değişmişlerse build normal nil-index hatasına düşer.
- Çalışma anı denetimi: durum makinesinin döngü gövdesinde her
  `plan.tick` dispatch'te bir (tohum 2–4 seçer) `debug.gethook`,
  `string.dump`, `string.char` kimlikleri, blok sayısı (`#bl<1`) ve toplam
  süre (`clk()-t0>25`) yeniden kontrol edilir. Yüklemeden sonra kurulan bir
  hook artık sadece yükleme anını değil tüm çözme/çalıştırma penceresini
  görür. Prologda standart global adlardan oluşan bir **chaff okuma tablosu**
  dolar, böylece ortam kayıt araçları gerçek okumaları gürültüden ayırmak
  zorunda kalır. Program çağrılmadan önce döngü sonrası bütün çözücü alanları
  `nil`'lenir (`fn` hariç); bellekte anahtar, alfabe, açılmış metin ya da
  tablo kalmaz. Kurcalama tespitinde `bad[1]=0` ile bilinçli nil-index
  hatası üretilir; hiçbir denetim adı ya da katman etiketi dosyada geçmez.
- Sınır: mühür üst sınırı `SEAL_VM_MAX` = 12 MiB; altında kalan her gövde
  boyuttan bağımsız mühürlenir (VM çıktısı 320 KB–2 MB arası tipik).
  2 MiB üstünde LZSS atlanır, >512 KB'da deneme sayısı 20'ye düşer; maliyet
  çıktı boyutuyla doğrusaldır. `sealWrap` kendi hatasında `nil` döner ve
  build düz compact çıktıya düşer, build asla bu yüzden düşmez. Bölünmüş
  build'de her parça kendi tohumuyla ayrı mühürlenir.
- Doğrulama: `print("h")` mühürlü çıktı altı tohumda 11 806–15 797 B
  aralığında (hepsi 7 satır, nonascii 0,
  `local` 0, `getfenv` 0, blob alanı her tohumda farklı); 34 621 baytlık
  game10 gövdesi 1 603 452 B / 12 blok mühürlü çıktı verdi ve native Lua 5.4
  ile Luau'da aynı stdout'u bastı; 360 060 baytlık v1big bölünmüş build'i
  4 746 063 B, 3 bağımsız mühürlü parça (3 `__call` stub'ı, 34 blob
  işareti) üretti ve doğrulamadan geçti; 12 modül × 5 host matrisi PASS.
  Tarayıcıda 34 621 baytlık girdi 5,5 s'de `integrity sealed` + `packing
  output` ile bitti, çıktı `return setmetatable` stub'ıyla başladı ve panel
  ilk 131 072 baytı önizledi. Ayrıca v1 motorunun kendi `getfenv()` çağrısı
  kaldırıldı (ortam `_ENV` → `_G`, `_G.type` yoksa bayt-kodlu `getfenv`
  yedeği); v1 suite'i 5 hostta PASS. Lua 5.1 hedef değil: compact motorun
  kendisi 5.1'de çağrı semantiğinde düşüyor (mühürsüz çıktı da aynı hatayı
  verir), mühür bunu değiştirmez.
- Dürüst sınır: yükleme öncesi kurulmuş bir `load`/`loadstring` hook'u çözülmüş
  metni yakalayabilir; istemci tarafında bu tamamen kapatılamaz, mühür yalnız
  yakalama sonrası analizi pahalılaştırır. 2 KB üstü scriptler zaten v2/M9
  paketli yola gider ve orada döküm VM'i verir, programı vermez.

### Integrity (katman 12)
- SipHash-2-4 (64-bit durum iki 32-bit yarıda, 2^53 altı aritmetik) canary ve
  prototip denetimleri; 128 KiB üstü ham blob için tuzlu FNV-1a yedeği.
- Üç canary her biri iki parça (`"a".."b"`) olarak gömülür; beklenen özet,
  uzunluk ve zincir değerleri tabloda çapraz kontrol edilir. Tek bir literal
  canary metni çıktıda görünmez.
- Altı döner kontrol noktası; her tick'te bir canary + iki örneklenmiş handler
  anahtarı denetlenir. Handler anahtarları `type()=="function"` **ve**
  `H[k]==HB[k]` (yüklemede alınan özel yedek tablo) ile doğrulanır.
- Yuvarlanan zincir: `c=(c*1664525+özet+uzunluk+i*2654435761+1013904223)%2^32`;
  her altı-tick döngüsünün sonunda `chain0`'a sıfırlanır. Eşik
  `IP = period + zincir%1021` ile tick aralığı jitter'lanır.
- İlk döngünün son kontrol noktasında bir kerelik tam denetim: `pairs(HB)` ile
  her anahtarın `H[k]==v` olduğu ve giriş sayısının beklenen toplamla eşleştiği
  doğrulanır; enjekte edilmiş/silinmiş handler yakalanır.
- Tüm durum tek `IZ` tablosunda tutulur (Luau 200 register sınırı); 32-bit
  sabitler `(a+b)%4294967296` biçiminde bölünür, anahtar malzemesi tek literal
  olarak görünmez.
- Tick'e `cfg.extra` ile ek koşul bağlanabilir; vmgen buraya yükleme-sonrası
  ilkel fotoğrafını (`IS`) koyar, böylece dump-hook tespiti de aynı sessiz
  nil-index hatasını üretir.
- Tüm başarısız kontroller tek mesaj üretir: `attempt to index a nil value`.
- Yardımcı fonksiyonlar (`q`, `r`, `h`) global'e yazılmaz; VM kapanışları
  içinde proto olarak yaşar, dışarıdan çağrılamaz.

### String şifreleme (katman 6)
- Şemalar: anahtar-akışlı XOR (LCG keystream + döner anahtar), özel alfabe
  Base64+XOR, Huffman+XOR, Feistel blok ağı (4-8 tur), lookup tablosu
  (white-box benzeri). XOR şeması artık tekrarlayan anahtar değil: salt'tan
  türeyen 32-bit LCG durumu (`st*1664525+1013904223 mod 2^32`) her baytta
  ilerler ve `floor(st/65536)%256` maskesi anahtar baytına XOR'lanır; aynı
  anahtar+salt farklı uzunlukta metinde aynı keystream'i üretmez, kısa
  metinlerde tekrarlayan-anahtar zafiyeti yoktur. Tüm aritmetik float
  alanında (`% 4294967296`) tutulur, Fengari'nin 32-bit tamsayısında da
  native ile birebir aynı keystream'i verir. Runtime çözücü (`R`) aynı
  LCG'yi aynen yansıtır.
- Her string için rastgele salt; aynı metin iki yerde farklı blob.
- Çözücü VM proto'su olarak derlenir; host Lua'da isimli fonksiyon kalmaz.
- Tuzak katmanı (varsayılan açık, `traps=false` kapatır): gerçek girdilerle
  aynı havuzda karışan decoy girdileri sahte endpoint/webhook/anahtar/identifier
  metinlerine çözülür ve hiçbir çağrı yerinden referans almaz; beş decoy aynı
  zamanda canary'dir (düz metin polinom hash'i çözücü kurulurken doğrulanır,
  uyuşmazlık sonraki tüm string'leri döndürülmüş hâlde verir). Havuz dışı
  indeksler `""` yerine deterministik hex token üretir; böylece toplu indeks
  taraması da sahte malzeme toplar.
- Çözücü yapısal olarak savunmacıdır: kısaltılmış/bozulmuş havuzda eksik alanlar
  sıfır varsayılır, geçersiz giriş `""` döndürür ve M11'in sessiz sapması
  (havuz harflerinin döndürülmesi) hata yerine yanlış veri üretir.

## Preset eşlemesi

| Preset | Katmanlar | Decoy | Self-mod | Anti-debug |
| --- | --- | --- | --- | --- |
| `fast` | 1,2,5(sayı),6(2 şema),7,8,9,12 | 80 | yok | yok |
| `normal` | 1-9, 11, 12 | 160 | yok | var |
| `strong` (varsayılan) | 1-12 | 160 | var | var |

`Obfuscate.DEFAULT_PRESET = "strong"`; preset bir tavan, `opts` alanları
(`decoys`, `flatten`, `opaque`, `selfmod`, `antidebug`, `integrity`, `schemes`)
tek tek ezilebilir.

CLI sözleşmesi:

```
lua v2/obfuscator.lua input.lua [output.lua]
    [--preset strong|normal|fast] [--seed N]
    [--run] [--auto-fix] [--stats]
    [--max-steps N] [--seconds N] [-o PATH]
```

Çıkış kodları: 0 başarılı, 1 kullanım/girdi, 2 obfuscation hatası,
3 doğrulama hatası. `--auto-fix` merdiveni `strong → normal → fast →
minimal`; `minimal` yalnız şifreleme + bytecode runtime'ı bırakır
(`integrity=false, decoys=32, schemes=1`). Parse ve scope hataları fatal'dır
(preset'ten bağımsız), compile hataları merdivende yeniden denenir.

## Doğrulama ve otomatik onarım (M12)

- `Autofix.sandboxRun` çıktıyı ayrı bir `_ENV`'de koşturur: `io`, `os.exit`,
  `dofile`, `loadfile`, `require`, `package` ve `debug` yazma yüzeyi kapalı;
  `print`/`io.write` tek bir tampona yazılır. Bütçe iki katmanlıdır: komut
  sayacı (`debug.sethook`, varsayılan 4×10^8) ve `os.clock` duvar saati
  (varsayılan 8-10 sn). Hook yoksa yalnız saat sayacı çalışır. Sayaçlar float
  alanında tutulur: Fengari'nin 32 bit `lua_Integer`'ı 2^31 üstünde negatife
  sarıp adım korumasını sessizce kapatmasın.
- Bütçe aşımı, adayın yanlış olduğunun kanıtı değildir. `Autofix.run` bunu
  "sandbox limit" olarak kaydeder, merdiveni durdurur ve çıktıyı
  `ok=true, stage="unverified"` ile korur; daha düşük preset aynı yükü
  ucuzlatmaz. Web paneli bütçeyi çıktı boyutuna göre ölçekler (ölçülen
  ≈750 komut/bayt üzerinden 1600 komut/bayt, 120 sn tavan), böylece 1 MB
  çıktı ~50 sn'de gerçekten doğrulanır.
- `Autofix.verify(source, code)` referansı ve adayı aynı sandbox'ta koşturup
  çıktı, dönüş değerleri ve hata durumunu karşılaştırır. Kaynak hata
  veriyorsa adayın da aynı mesajı vermesi gerekir; iki taraf da hatasızsa
  çıktı bayt bayt eşleşmelidir.
- `Autofix.run` merdiveni yukarıdaki sırayla dener, her denemeyi
  `{index, label, preset, ok, match, reason, ms}` olarak kaydeder ve ilk
  eşleşen çıktıyı döndürür. Tüm preset'ler tükenirse `stage="exhausted"`.
- `run.py --module 12` 87 kontrolle şunları kapsar: integrity planı/hash'i,
  üç parçalı canary, altı kontrol noktalı zincir ve handler yedeği denetimi,
  gömülü canary ve blob kontrolü, tamper vakaları, geç-hook mandalının tick'e
  bağlandığı, hook'lu hostta sessiz sapma, sandbox izolasyonu (`print`/
  `io.write` sıralı yakalama, `io.open` ve `os.exit` engeli, adım limiti,
  deterministik ortam), referans/aday karşılaştırması, kasıtlı bozuk çıktıda
  onarım, compile hatasında merdiven tırmanışı, tükenme ve fatal parse yolu,
  CLI argümanları/çıkış kodları ve dosya yazımı, 5 seed'de 5 farklı çıktı,
  aynı seed'de aynı çıktı, bütçe aşımında çıktının korunması ve 302 satırlık
  benchmark (995 350 B, 1440 ms).

## Test ve kabul planı

1. **M1**: token kapsamı, AST sözleşmesi, Lua 5.1/5.3/5.4/Luau sözdizimi,
   goto/label, hata satır-sütun ve kurtarma.
2. **M2-M6**: kapsam/upvalue testleri, flatten semantiği, opaque truth tablosu,
   sabit geri çözümü, 5 string şemasının round-trip'i.
3. **M7-M12**: cross-runtime matris (5.1, 5.2, 5.3, 5.4, Luau), 1000 satır
   benchmark, 10× polimorfizm, `strings` taraması, dump/tamper saldırıları.
4. Her modül sonunda yalnız o modülün testi çalıştırılır; kabul için
   `MODÜL N TAMAM, test sonucu: PASS` üretilir ve onay beklenir.

## Modül durumu

| Modül | Durum | Kanıt |
| --- | --- | --- |
| M1 | PASS (2026-11-07) | `tests/run.py`: 77/77 kontrol, Lua 5.1/5.2/5.3/5.4 + native 5.4 |
| M2 | PASS (2026-11-07) | `tests/run.py --module 2`: 249/249 kontrol, 5 host; 1750 satır → 15 ms |
| M3 | PASS (2026-11-07) | `tests/run.py --module 3`: 227/227 kontrol, 5 host; 300 dal → 602 state, router derinliği 11, ≤75 ms |
| M4 | PASS (2026-11-07) | `tests/run.py --module 4`: 253/253 kontrol, 5 host; 150 dallı fonksiyon (755 koşul) 80 ms, 10/10 polimorfizm |
| M5 | PASS (2026-11-07) | `tests/run.py --module 5`: 283/283 kontrol, 5 host; 301 literal 13 ms, 31 şablon, 10/10 polimorfizm |
| M6 | PASS (2026-11-13) | `tests/run.py --module 6`: 217/217 kontrol, 5 host; 300 literal → 14 505 B havuz (90 decoy) 63 ms, 6 şema, 10/10 polimorfizm, trap/canary/OOB/tamper testleri; 2000 stringlik havuzun çözücüsü tek ileri yürüyüş (doğrusal) |
| M7 | PASS (2026-11-07) | `tests/run.py --module 7`: 312/312 kontrol, 5 host; 364 satır → 14 589 komut 111 ms; corpus 73/80 opcode + 7 doğrudan handler, 80 ISA |
| M8 | PASS (2026-11-07) | `tests/run.py --module 8`: 238/238 kontrol, 5 host; 29 program corpus, 240 anahtar (80+160), 10/10 farklı build, 364 satır → 224 700 B / 15 ms |
| M9 | PASS (2026-11-09) | `tests/run.py --module 9`: 94/94 kontrol (5.1'de alt-tip kontrolleri atlanır), 5 host; 14/14 corpus, 10/10 blob/kaynak/anahtar, 9/9 yayımlanmış SipHash vektörü, 300 satır → 1919 komut, 12 676 B blob / 71 526 B kaynak, pack 13 ms; 2000 stringlik program 1.21 s build (ChaCha bit hızlı yolu 5.5×) |
| M10 | PASS (2026-11-08) | `tests/run.py --module 10`: 71/71 kontrol (5.1'de 69; alt-tip kontrolleri atlanır), 5 host; 14/14 corpus, 10/10 blob/kaynak, 300 satır → 1919 komut / 480 blok / 256 komut canlı pencere, 16 289 B blok → 19 172 B blob / 92 856 B kaynak, 416 yerinde yeniden şifreleme, derleme 14 ms + pack 34 ms |
| M11 | PASS (2026-11-13) | `tests/run.py --module 11`: 4738/4738 kontrol, 5 host; 14/14 corpus, 14/14 hook'lu sağkalım, 20 seed'de 20 farklı prob seti, 10/10 polimorfizm, **33 prob** (xpcall/desen/coroutine/kaynak-bilgisi/len-unpack/meta/gc dahil), **ADN prob-şekli sağlaması**, geç-hook mandalı (iki vuruş eşiği, temiz host/executor/yükleme-sapması sıfırlar), 300 satır → 435 058 B kaynak, derleme 73 ms + build 153 ms, yükleme tabanı 209 ms / problu 214 ms; hook'lu çıktı 34 baytlık metnin 18 baytında sapıyor, hata yok; sapma rakamlar dışındaki tüm baytları döndürüyor ve build-özel `salt` (0..191) taşıyor |
| M12 | PASS (2026-11-13) | `tests/run.py --module 12`: 90/90 kontrol, 5 host; üç parçalı canary + altı kontrol noktalı zincir + `pairs(HB)` tam handler denetimi, canary/blob/handler tamperi, geç-hook mandalının tick'e bağlanması, 25 ortam gürültüsü okuması, **35 girişlik yükleme-sonrası ilkel fotoğrafı** (28 ek giriş `not ADE` kapılı; program çalışırken `string.dump` değişimi tick'i düşürüyor), hook'lu sessiz sapma, sandbox izolasyonu, onarım merdiveni, CLI/çıkış kodları, 5 seed → 5 farklı çıktı; 302 satır → 1 012 367 B / 1177 ms; compact tiny (`print("h")`) 12 707 B, 360 KB giriş → 4 773 761 B / 21.6 sn + doğrulama PASS; tarayıcıda örnek build OK |

2026-11-09 güçlendirme geçişi (17 maddelik gereksinim dosyası): M6 XOR
şeması anahtar-akışlı LCG cipher'a yükseltildi; M8 sıcak opcode'lara
polimorfik handler varyantları eklendi (`VMGen.VARIANTS`); M11 dokuz proba
çıkarıldı ve reload (anti-dump) probu her build'de zorla açık, ağırlık 2;
M4 string primitifleri `("\0").char` yerine rastgele kaçışlı literal'den
türetiliyor; `obfuscate.run`'a `executor`/`gethui`/`antiwebhook` kapıları
eklendi; web konsoluna Rules + Araçlar (loadstring/200-bypass/deobf)
bölümleri ve doğru "yerel · ağ gerekmez" etiketi geldi. Tam 12×5 matris
bu değişikliklerden sonra yeniden PASS; çıktı tek satır ve katman etiketi
sızıntısı yok (grep audit: NONE).

2026-11-10 güçlendirme geçişi: M8 `VMGen.VARIANTS` 17'den ~57 opcode'a
çıkarıldı (MOD/POW/IDIV/UNM/CONCAT/BAND..SHR/K-varyantları/upvalue-cell/
tablo-alan/SELF dahil; hepsi anlamsal eş, metamethod sırası korunur) ve decoy
havuzu 9 yeni zararsız no-op kazandı. M11 onuncu probu aldı: global `type`
bütünlüğü; reload'un zorla-açık biti artık isimle aranıyor, böylece liste
büyüse de anti-dump garantisi kaymıyor. Web Araçlar'a dördüncü kart **Dumper**
eklendi (statik: char/byte tablosu, kaçışlı literal, `string.rep`/`:rep`/
`:reverse`, base64, `\xHH` hex blob'ları ve tek-byte XOR brute force; rapor
satır numarası + önizleme verir, hiçbir zaman yapıştırılan kodu çalıştırmaz).
Deobfuscator aynı geçişlerle derinleşti: kaçış çözme, rep/reverse katlama,
`table.concat({..})` ve hex argümanlı `string.char` desteği. Konsol ızgarası
4 kart için 2 sütuna alındı. Tam 12×5 matris yeniden PASS.

2026-11-12 anti-tamper geçişi: M12 tek canary/tek nokta denetiminden **üç
parçalı canary + altı döner kontrol noktası + yuvarlanan zincir** yapısına
taşındı. Her tick bir canary'nin SipHash'ini, uzunluğunu ve zincir değerini
birlikte doğrular; iki örneklenmiş handler anahtarı `type()=="function"` ve
yüklemede alınan `HB` yedeğiyle özdeşlik üzerinden kontrol edilir. İlk
döngünün son noktasında `pairs(HB)` ile bir kerelik tam tablo denetimi ve giriş
sayısı karşılaştırması çalışır. Periyot `period + zincir%1021` ile jitter'lı,
döngü sonunda zincir `chain0`'a döner; 32-bit sabitler `(a+b)%2^32` olarak
bölünür ve tüm durum tek `IZ` tablosunda yaşar (Luau 200 register sınırı).
M11 yükleme sonrası kurulan hook'lar için iki-vuruşlu `ADH` mandalı kazandı;
mandal temiz/executor olmayan oturumda ilerler, `gethook()` nil dönerse
sıfırlanır, iki ardışık vuruş M12 tick'inde `ADH>=2` ile normal nil-index
hatasına dönüşür. Autofix sandbox'ı ve hooksuz host'lar yanlış pozitif
üretmez. Tam 12×5 matris (60/60), compact tiny (13 439 B), 360 KB giriş
(4 307 983 B) ve tarayıcı smoke testi PASS.

2026-11-12 ikinci sertleştirme geçişi (env log / dump / deobf): M11 prologuna
tohumdan seçilen **25 sahte ortam okuması** eklendi; okumalar iki karışık blok
hâlinde gerçek yakalamaların önüne ve arkasına düşer, yalnız `CH` tablosuna
yazılır ve `pcall` içinde kalır. M12 tick'ine `cfg.extra` koşulu açıldı ve
vmgen buna **yedi girişlik yükleme-sonrası ilkel fotoğrafı** bağladı:
`debug.gethook/getinfo/getupvalue/getregistry`, `string.dump`, `load`,
`loadstring`. Çalışma sırasında bu girişlerden biri değiştirilirse (dump/devirt
harness'larının tipik müdahalesi) tick normal nil-index hatasını üretir; eksik
girişler (Luau, kısıtlı sandbox) nil saklanıp atlanır, yanlış pozitif yok.
Bu geçişte `BOOL` handler'ının bir varyantındaki nil/false polarite hatası da
düzeltildi (test 8 bunu rastgeleleştirme akışı değişince yakaladı). 12×5 matris
(60/60), compact tiny (13 467 B), 360 KB giriş (4 311 338 B / 13.2 sn +
43.8 sn doğrulama), Luau çalıştırması ve tarayıcı build'i PASS.

2026-11-12 üçüncü geçiş (compact çıktı dökümü): compact motorun çıktısı
okunabilir VM gövdesi bıraktığı için dökümde `local`/`end` satırları
görünüyordu. Web driver'a **mühür katmanı** eklendi: LZSS paket + 16 baytlık
build anahtarıyla XOR + 91 sembollü alfabede base91 (13 bit/çift) + rastgele
dolgu. Çıktı artık dört satır: açılış `return setmetatable`, tek satır blob,
tek satır çözücü, kapanış. `print("h")` 14 292 B (tek blob satırı ~12.5 KB),
nonascii 0; 954 baytlık örnek 36 307 B düz gövde yerine 22 598 B mühürlü çıktı;
Autofix doğrulaması PASS, Luau ve Lua 5.2–5.4 aynı çıktı, tarayıcı build'i
görsel olarak doğrulandı. 12×5 matris (60/60). v2 yolu değişmedi: 11.7 KB
kaynak → 691 035 B tek satır paketli çıktı.

2026-11-12 dördüncü geçiş (local yok + durum makinesi): mühür çözücüsü
kullanıcı isteğiyle `local` bildirimlerinden tamamen arındırıldı ve tek bir
durum makinesine çevrildi. Alan adları (47 rol), durum numaraları, aşama
sırası ve alfabe/anahtar tohumdan üretilir; her aşama dispatch tablosunda
`[sayı]=function(P) … return <sonraki> end` biçiminde durur, gövde tek
`while <durum> do … end` döngüsüdür, iki decoy döngüsü hiç çalışmaz. Tüm
durum `__call` parametresinin alanlarında yaşadığı için çıktıda tek bir
`local` kelimesi yok (grep 0), nonascii 0. Ortam anahtarları çalışma anında
bayt kodlarından kurulur; `string.dump`/`debug.gethook` kimlikleri yükleme
öncesi alınıp `load` sonrası karşılaştırılır, blob 8 sembolden kısaysa çözücü
başlamaz, prologda 11 standart globalin chaff okuması yapılır. Ölçümler:
`print("h")` 4 tohumda 11 969 / 12 325 / 14 101 / 15 836 B (5 satır, tarayıcı
12 617 ve 13 534 B), 1 053 baytlık örnek 25 044 B ve Autofix PASS, Luau +
Lua 5.4 aynı çıktı, 12×5 matris (60/60), index.html 1 348.4 KB.

2026-11-12 beşinci geçiş (ortam günlüğü izlerini sil): kullanıcı bir Dex
ortam günlüğünü "dump" sanıp daha da güçlendirme istedi. Günlük kod dökümü
değil, çağrı kaydıdır; yine de çözücünün kendi izleri azaltıldı. (1) Blob,
alfabe ve anahtar `setmetatable` argümanından çıkarılıp `__call` içinde `P`
alanlarına atandı; dışarı verilen tablo artık `{}` olduğu için günlüğe
serileşecek blob kalmıyor, ilk satır `return setmetatable({},{__call=…)`.
(2) `env` rolü ve prologdaki ortam tablosu kaldırıldı (47 → 46 rol);
kütüphaneler doğrudan chunk ortamından okunuyor, `_ENV` yalnız 5.2+ yükleme
yolunda, `getfenv(1)` yalnız 5.1 dalında geçiyor — Luau'da `getfenv` hiç
çağrılmıyor, `debug`/`dump`/`gethook` hâlâ bayt-kodlu. Blob uzunluğu, `load`
sonrası fonksiyon tipi, `string.dump` ve `debug.gethook` kimlik denetimleri
korundu. Ölçümler: `print("h")` 4 tohumda 13 006 / 14 580 / 12 915 / 14 013 B
(6 satır, `local` 0, nonascii 0), tarayıcı 15 051 B; 1 153 baytlık örnek
22 680 ve 23 777 B, Luau ve Lua 5.5 aynı çıktı, Autofix PASS, 12×5 matris
(60/60), index.html 1 348.2 KB.

2026-11-12 altıncı geçiş (akış şifresi, checksum, döngü içi denetim): mühür
yükseltildi. (1) Sabit anahtarlı XOR yerine **konum-bağımlı akış şifresi**:
LCG durumu anahtar sembolü ve bayt sırasıyla ilerliyor, anahtar akışının üst
ya da alt baytı tohumla seçiliyor, her bayt bir önceki düz bayta zincirleniyor
ve nibble tablosundan geçiyor. (2) Başlığa yükün **FNV-1a32** özeti eklendi;
tek sembollük kurcalama bile artık hata veriyor. (3) Durum makinesinin
döngüsünde her 2–3 aşamada bir `debug.gethook`, `string.dump`, `string.char`
kimlikleri ve blob uzunluğu yeniden kontrol ediliyor — yükleme sonrası hook
artık çözme penceresini de görüyor. (4) Program çağrılmadan önce bütün çözücü
alanları `nil`'leniyor. (5) Anahtar sayı tablosu yerine alfabe dizgesinde
tutuluyor, permütasyonla okunuyor; rol sayısı 50 → 55, ortam anahtarları ve
`char`ın kendisi de bayt-kodlu. (6) Bu sırada bulunan asıl sızıntı **v1
motorundaydı**: `N.E=_ENV or (SG and SG())` her Luau çalışmasında `getfenv()`
çağırıyordu (Dex günlüğündeki `getfenv(1) -- Ran` satırı). Artık ortam önce
`_ENV`, sonra `_G` (`_G.type` varsa), en son bayt-kodlu `getfenv` yedeği;
test probunda `getfenv` hiç çağrılmıyor. Ölçümler: `print("h")` altı tohumda
11 847 / 12 182 / 15 086 / 12 466 / 15 194 / 12 584 B (7 satır, `local` 0,
`getfenv`/`debug`/`dump`/`gethook` 0, nonascii 0), Luau + Lua 5.4 + Lua 5.5
aynı çıktı, tek sembol tamperi hata verdi, v1 suite 5 hostta PASS.

2026-11-12 yedinci geçiş (v2 ortam edinimi): aynı Dex günlüğü bu kez 3 893
baytlık Shop örneğiyle (v2 motoru) alındı; günlükteki tek obfuscator izi
`getfenv(1) -- Ran` satırıydı, kaynağı v2 VM sarmalayıcısının ortam edinimi.
Sıra artık şu: `_ENV` → (`_VERSION` "Luau" ise) `_G` üzerinde `print` probu
→ bayt-kodlu `getfenv` yedeği → `_G`. `_G` yalnız Luau'da ve standart bir
global görünüyorsa kabul edilir; klasik 5.1'de `setfenv` ile kurulmuş sandbox
ortamını atlamamak için o dal hiç çalışmaz (ilk denemede M12'nin 5.1 sandbox
kontrolü tam bunu yakaladı). Sarmalayıcının kendi bayt-çözücüsü ortam
bloğunun önüne alındı; dosyada artık tek `setmetatable` (dönen tablo) ve tek
`getfenv` (yalnız yedek) geçiyor, Dex günlüğünde `setmetatable`, `pairs`,
`__index`/`__metatable` satırlarının hepsi Dex'in kendi probları. Doğrulama:
M12 ve M11 5/5, M7/M9/M10 5/5, Luau'da getfenv sarmalayıcı probu 0 çağrı ve
program çıktısı birebir, tarayıcı derlemesi çalışıyor, index.html 1 354.8 KB.

2026-11-12 sekizinci geçiş (v2 çıktısını mühürleme): rakip örneklerin (Luraph
14.8–15.1, AntiLua 12.1, Fulcrum, PSU, MoonVeil, ironbrew) ortak özelliği,
dosyanın tek bir uzun bracket bloğu + küçük yükleyici olması; bizim v2
çıktımız ise okunabilir VM gövdesiydi. Tek parçalı v2 build'leri artık aynı
mühürden geçiyor: LZSS → konum-bağımlı akış şifresi → base91 → dolgu, yani
dosyada VM gövdesi hiç görünmüyor. Ölçümler: 3 893 B örnek 470 393 B →
**237 228 B** (build 1.0 s, Luau'da çözme+çalıştırma 0,48 s); 46 KB giriş
898 066 B → 835 401 B (içerik az tekrarlı, kazanç %7; Luau'da toplam 2,3 s).
Üst sınır `SEAL_VM_MAX` = 12 MiB ve gövde 128 KiB'lik bloklar hâlinde
mühürlenir; parçalı (split) yol da her parçayı ayrı mühürler, yani 320 KB
üstü girdilerde de dosyada okunabilir VM gövdesi kalmaz. Mühür ayrıca **CPU
zamanı tripwire'ı** kazandı: prologda `os.clock`
alınıyor, her denetim turunda toplam süre 25 s'yi aşarsa build sessizce
nil-index hatasına düşüyor (tek adım debugger için; yavaş executor'lar CPU
saatiyle ölçüldüğü için tetiklenmez, `os` yoksa denetim atlanır). Doğrulama:
altı compact tohumu 13 199–15 810 B, COMPACT PASS; v2 mühürlü build Autofix
PASS; tarayıcıda Shop örneği 1,0 s'de mühürlü çıktı veriyor; index.html
1 356.3 KB.

2026-11-13 anti-debug geçişi ("ciddi güçlendir"): M11 prob listesi **25 → 29**
oldu: `xpcall` çoklu dönüş/hata yönlendirme, desen motoru (`gsub` callback +
`gmatch` sayısı), coroutine durumları (yield/resume/wrap) ve `getinfo(fn,"S")`
kaynak bilgisi. Dördü de executor'da `AMBIGUOUS`/`SOFT` sınıfında, yani
sarmalanmış olsa bile çalışan bir executor'ı düşürmüyor; düz host'ta ise
instrumentasyonu yakalıyor. Yeni **prob şekli sağlaması** (`ADN`) her prob
bloğunun başına tohumdan türetilmiş bir token ekleyip toplamı prologda
doğruluyor; bir bloğu silmek/sıralamak/yamalamak sapmayı sessizce tetikliyor.
Yükleme-sonrası ilkel fotoğrafı 7'den **35 girişe** çıktı (debug, coroutine,
ortam, string, table/math fonksiyonları); 28 ek kontrol `(not ADE)` kapılı
olduğu için sağlıklı executor yanlış pozitif üretmiyor. Doğrulama: 12×5 matris
(60/60), compact tiny 12 707 B (COMPACT PASS), 34 621 B giriş → 1 587 849 B
(6.0 s, verify OK), 360 060 B giriş → 4 773 761 B / 3 parça (21.6 s, verify OK);
gerçek 405.6 KB build Lua 5.4 ve Luau'da birebir aynı çıktı, `debug.sethook`
kurulu host'ta hata vermeden baytları döndürdü, executor simülasyonunda
(`getgenv` + hook) çıktı temiz kaldı; index.html 1 377.5 KB, tarayıcı
derlemesi hatasız (17 326 B çıktı).

2026-11-13 konsol geçişi ("çıktı hep sıkışık olsun + execute/onar"): `sealStub`
artık tek fiziksel satır üretiyor, yani mühürlü dosyada yalnız banner yorumu
ve `return setmetatable({},{__call=function(P,...)` ile başlayan blob satırı
görünüyor; kullanıcının ekran görüntüsündeki `return P.<fn>(...)` / `end})(...)`
epiloğu artık ayrı satır değil. Onarım (`fix`) eylemi de aynı `sealWrap`'ten
geçiyor, yani düzeltilmiş çıktı asla okunabilir VM bırakmıyor. Konsol her
build'den sonra çıktıyı kaynakla birlikte sandbox'ta çalıştırıyor (`run`
eylemi; bütçe `runBudget`'a bağlı, ilk tur 8 s, sınırda 3× genişletme); çıktı
eşleşmezse onarım merdiveni (`fix`) taze tohumla en çok 3 tur çalışıyor ve her
tur yeniden doğrulanıyor. Ayarlar kartında yalnız `Use Gethui` ve
`Anti-Webhook` var (güç/preset ayarı yok, tüm katmanlar sabit); seçim
`clax.opts.v1`'de saklanıyor. Uçtan uca zincir: 6 565 B kaynak, kasıtlı yanlış
çıktıyla `run` → `output mismatch` (62 ms) → `fix` 3,6 s / 446 KB mühürlü tek
satır → `run` tekrar → `ok` (3,1 s). `print("h")` 12 305 B (COMPACT PASS,
Luau `h`), 34 621 B `game10` → 1 587 848 B tek satır, Lua 5.4 çıktısı kaynakla
birebir; 12×5 matris 60/60; index.html 1 386.8 KB, tarayıcıda 98 B kaynak
13 151 B tek satır + "çalıştırıldı · çıktı eşleşti", 6 565 B kaynak da aynı
notla doğrulandı.

2026-11-13 sertleştirme geçişi (VM / opcode / anti-debug / bytecode / string):
M8 encoding sayısı **10 → 14** (80×14 = 1 120 gerçek anahtar); ikinci eşdeğer
gövde grubu (`EXTRA_VARIANTS2`) 23 opcode'a yayıldı ve `TEST` varyantındaki
ters dal düzeltildi (ham `TEST` atlaması sessizce yanlış `pc`'ye gidiyordu;
module8 artık bu yolu çalıştırıyor). M9'da her prototipin sabit bölümü ikinci
kez, `(key, proto, uzunluk)`'tan türeyen durum ve önceki şifreli baytı zincire
katan LCG akışıyla mühürleniyor; çözücü bölümü ilk sabit okumasında açıyor.
M6 altıncı şemayı (`chain`) aldı, decoy oranı `%45` (üst sınır 90, alt sınır
12); 300 stringlik havuz 14 505 B / 90 decoy / 63 ms, 217/217 kontrol.
M11 prob listesi **29 → 33**: `len`, `unpack`, `meta` (referans `__index`
tablosu; metin `__index` geçersiz Lua olduğu için temiz host'u yanlış
işaretliyordu) ve `gc`; mask baskısı 64-bit maskeyi taşırabildiği için testte
`%.0f` kullanılıyor.

Ortam edinimi yeniden sıralandı: `_ENV` yoksa ve `_VERSION=="Luau"` ise önce
`pcall(getfenv)(1)` denenir (chunk ortamı), yalnız başarısızsa `_G`'ye düşülür.
Sebep: Luau safeenv `_G`'yi donduruyor ve split parçaları arası değerler
`SETGLOBAL` ile taşınıyor; eski sıra parçalı çıktıyı "readonly table" hatasına
düşürüyordu. `Big.header` artık parçaları yazılabilir bir vekil tablo
(`setmetatable({},{__index=getfenv()})`) altında `setfenv` ile çalıştırıyor;
mühür yükleyicisi de `load` sonrası stub'ın ortamını yeniden uyguluyor.
Doğrulama: 12×5 matris 60/60; `print("h")` 12–15 KB bandında (COMPACT PASS);
4,86 MB / 3 parçalı çıktı Lua 5.4 ve Luau'da bayt bayt aynı; 1,62 MB hedefte
çıktı iki hostta aynı; tarayıcı derlemesi "çalıştırıldı · çıktı eşleşti".

M1 notu: sözlükçü ve ayrıştırıcı motoru v1'deki test edilmiş uygulamadan
devralındı; v2'ye özgü olan `type/children` sözleşmesi, doğrulayıcı, metin
dökümü ve 77 kontrollük kabul testidir. Devralma sırasında `return -1` /
`return -x` biçimindeki tekli ifadelerin "değer yok" sayıldığı bir hata
bulundu; hem v2 hem v1 düzeltildi.

M2 notu: `scope.analyze` AST'yi yerinde etiketler (`bindingId`, `refKind`),
`scope.apply` isimleri yeniden yazar. Değişken çözümü tüm sözlüksel zinciri
dolaşır (upvalue'lar bu yüzden çalışır); etiketler ise fonksiyon sınırında
durur. `_ENV`/`_G` rezerve, globaller hiç dokunulmaz. Kabul testi yalnız yapı
karşılaştırması yapmaz: aynı programı (a) kaynak, (b) AST'den yeniden basılmış,
(c) yeniden adlandırılmış hâliyle 5 hostta çalıştırıp çıktıları karşılaştırır.
Testlerde kullanılan `tests/emit.lua` boru hattının parçası değildir; M7
bytecode üretecektir.

M3 notu: `flatten.run` ana chunk'ı, fonksiyon gövdelerini ve döngü gövdelerini
state machine'e çevirir. Dağıtım ikili arama ağacıdır (O(log n), lineer
`elseif` yok); state kimlikleri seed'e bağlı Fisher-Yates permütasyonudur.
Bölge içindeki `local`/`local function` bildirimleri makinenin başına taşınır
ve atamaya dönüşür; M2 her bağlama tekil isim verdiği için bu taşıma ne
gölgeleme ne birleşme yaratır. Döngü gövdesinde makine her yinelemede yeniden
kurulduğundan yineleme başına taze local/closure kimliği korunur; `repeat`
gövdesindeki taşınmış local'lar `until` koşulundan hâlâ görünür. `break` ve
`continue` -1/-2 sentinel'ine dönüşür, makine bittikten sonra gerçek `break` /
`continue` olarak yeniden yayılır. goto/label, `<const>`/`<close>`, `_ENV`/`_G`
yerel bildirimi, tekrarlı isim (M2 uygulanmamış AST) ve 185 local bütçesi
aşılan bölgeler dokunulmadan bırakılır. Kabul testi aynı programı kaynak,
yalnız yeniden adlandırılmış ve düzleştirilmiş hâliyle 5 hostta çalıştırır;
ayrıca router derinliğinin `ceil(log2 state)+1` sınırında kaldığını, 10 seed'in
10 farklı çıktı ürettiğini ve 300 dallı fonksiyonun 75 ms'de derlendiğini
doğrular.

M4 notu: `opaque.run` her koşul konumunu (`if`/`elseif`, `while`, `repeat
until`, Luau if-expression) her zaman doğru ya da her zaman yanlış bir tamsayı
özdeşliğiyle sarmalar; 11 doğru ve 10 yanlış şablon, 7 sarma biçimi vardır ve
her ikisi de seed'den seçilir. Özdeşlikler yalnız `+ - * % == ~=` kullanır:
Lua 5.1'de bit operatörü yok ve `%` beş hostta da taban modülüsüdür, bu yüzden
negatif `v` dahil tüm tamsayılarda geçerlidirler. Sarma biçimleri yalnız
doğruluk değerini korur (`0` ve `""` Lua'da doğrudur); özgün koşul her zaman
ilk ve tam bir kez değerlendirilir, dolayısıyla yan etki ve kısa devre
değişmez. Önermeler saf aritmetiktir, kullanıcı verisine dokunmaz (NaN/float
sızması yok). Koşulu olan her sahip (chunk veya fonksiyon) için tek bir
16-hex tamsayı local'i gövdenin başına eklenir; 190 local bütçesine yakın
sahipler, `prob` ve `enabled` kapıları atlanır. Kabul testi 21 şablonu 14
pozitif/negatif değer üzerinde, 7 sarmayı 9 doğruluk değeri üzerinde ayrı ayrı
çalıştırır; ayrıca katman 1-4 boru hattını 21 programda 5 hostta kaynak
çıktısıyla karşılaştırır, tek değerlendirme ve kısa devre sayımlarını
doğrular, 10 seed'in 10 farklı çıktı ürettiğini ve 755 koşullu 150 dallı
fonksiyonun 80 ms'de işlendiğini ölçer.

M5 notu: `consts.run` M2'den hemen sonra çalışır; Flatten ve Opaque'un
ürettiği yapısal sabitler (state kimlikleri, router karşılaştırmaları,
predicate tohumları) zaten M7/M9'da şifreli bytecode'a gireceği için onları
gizlemek yalnız ağacı büyütürdü. Sayılar 12, float'lar 5, `true`/`false` 5+5,
`nil` 4 şablonla gizlenir ve her sabit kendi seed'ine göre seçilir. Tamsayı
şablonları yalnız `+ - *` kullanır ve 2^52 sınırının altında kalır; böylece
sonuç beş hostta da (5.1'in tamsayı alt tipi olmadan) bit düzeyinde aynıdır.
Float'lar yalnız ikiye bölme/çarpma ve işaret çevirme kullanır (tam ikili
işlemler), bu yüzden `1e-300` dahil yuvarlama sapması oluşmaz. Eksi sıfır
gizlenmez (bir aritmetik onu sessizce +0'a çevirebilir ve `1/x` farkı görür);
tam değerli float literalleri (`0.0`, `2.0`) metin biçiminden tanınıp float
şablonlarına yönlendirilir, böylece 5.3+ alt tipi ve `tostring` çıktısı korunur. `nil`
şablonları tek sonuçlu `("")[1]` / `({})[1]` indeks ifadeleridir; `select('#')`
arity'si korunur. `true`/`false` yalnız karşılaştırma üretir, `nil` ve boolean
tanımlayıcı yaratılmaz; M2 tek isim otoritesi olarak kalır. `synthetic`
işaretli düğümler tekrar işlenmez (idempotent), `TableField.key` düğüm
referansı çocuk dizisinde yer değiştirince yeniden bağlanır. 2^52 ve üstü
tamsayılar, `floats=false` veya `minFloat` altı float'lar, NaN/sonsuz ve
`prob` kapısı atlanır. Kabul testi 31 şablonu değer bazında (`select('#')`
dahil) 5 hostta çalıştırır, katman 2-5 boru hattını 18 programda kaynak
çıktısıyla karşılaştırır, 10 seed'in 10 farklı çıktı ürettiğini ve 301
literallik programın 13 ms'de işlendiğini ölçer.

M6 notu: `strings.run` son yapısal geçiştir; Flatten ve Opaque'un ürettiği
sabitleri/koşulları yeniden işlemez, yalnız kalan `String` düğümlerini tek bir
çözücü çağrısına indirger. Her string kendi 16-bit salt'ı, 2-7 baytlık anahtarı
ve şemasıyla şifrelenir; aynı metin iki yerde aynı baytları paylaşmaz. Beş
şema (döner XOR, karışık alfabeli Base64+XOR, string başına Huffman+XOR,
4-8 turlu 8-bit Feistel, salt'lı 256 girişli S-box) saf aritmetiktir; 5.1'de
bit operatörü ya da `string.pack` yoktur. Şema kimlikleri build başına
1..255 aralığında permüte edilir ve şemalar karıştırılmış desteden sırayla
seçilir, böylece tüm şemalar kullanılır. Şifreli metin tek, kendini tanımlayan
bayt havuzunda toplanır (`şema, anahtar, salt, uzunluk, meta, blob`); çözücü
havuzu sırayla tarayıp ofsetleri önbelleğe alır, çözülen string'i de önbelleğe
alır. Ofset yürüyüşü son bilinen girişten ileri devam eder (`FI`/`FP`), böylece
havuz kaç indeks istenirse istensin tek kez taranır; her yeni indekste 1.
girişten başlayan eski yürüyüş büyük havuzlarda ikinci derecedendi ve 2000
stringlik programın decoder'ını gereksiz yavaşlatıyordu. `{ a = 1 }` gibi isim alanları `[çağrı] = ...` biçimine çevrilerek anahtar
metni de gizlenir; boş string, `prob` ve `minLength` kapıları atlanır.
Çözücü tek bir fonksiyon değeri olarak chunk başına bağlanır; bu ad program
değişkeni değil runtime iskeletidir, tüm ağaçtaki isimlerle çakışmayacak
şekilde seçilir ve M7 onu VM proto'suna katınca host'ta isim kalmaz. `synthetic`
işaretli alt ağaçlar tekrar işlenmez (idempotent). Kabul testi altı şemayı 12
değerde (ikili baytlar, tek sembollü Huffman, 200 baytlık metin) çalıştırır,
boru hattını 19 programda kaynak çıktısıyla karşılaştırır, havuzun kaynak
metnini sızdırmadığını, her girişin build çözücüsüyle açıldığını, şema
kimliklerinin permüte edildiğini ve 10 seed'in 10 farklı çıktı ürettiğini
doğrular; 300 literallik program 8237 baytlık havuza 33 ms'de iner.

M7 notu: `compiler.compile` AST'yi 80 opcode'luk register ISA'ya indirir
(`{op,a,b,c,d}`; sabit/immediate operandları `d` alanında). Şablon eşlemesi
M8'den bağımsızdır. Yakalanan local'lar tek elemanlı hücre tablosudur:
`NEWCELL/GETCELL/SETCELL`, closure'a hücrenin kendisi geçer, böylece upvalue
paylaşımı Lua semantiğiyle birebir aynıdır; ara fonksiyonlardan geçen
upvalue'lar `{0,index}` zinciriyle taşınır ve `updesc` CLOSURE anında kurulur.
Döngü değişkeni closure'la yakalanırsa her yinelemede taze hücre açılır.
Çoklu dönüşler tek bir `top` işaretçisi ve `-1` sentinel'iyle çözülür
(CALL/VARARG/RETURN/SETLIST); kuyruk çağrısı `TAILCALL`'a düşer. Aritmetik
için `ADDK..IDIVK` sabit ve `ADDI..MODI` tamsayı-immediate biçimleri, yalnız
sağ taraf düz sayı olduğunda seçilir; M5 sonrası saklanmış sabitler bu yolu
kullanmaz. Bitwise komutlar 5.1 uyumlu 53-bit aritmetik sözleşmesini izler;
`IDIV` taban bölmedir ve `BNOT` `-x-1`'dir. `goto`/`label` fonksiyon
genelinde çözülür, `break`/`continue` döngü yığınıyla hedefe atlar. Derleyici
AST'yi değiştirmez, yalnız `_protoIndex` etiketler; hata durumunda istisna
atmaz, `errors` listesi döndürür. `Compiler.validate` proto sayısı, `updesc`
şekli, bilinmeyen opcode, sabit/proto indeksleri ve jump aralığını denetler.
Kabul testi 73 opcode'u gerçek programlarla, kalan 7'yi (`BOOL`, `TEST`,
`TESTSET`, `TESTNIL`, `NOP`, `CLOSE`, `SETTOP`) elle kurulmuş proto'larla
çalıştırır; corpus'u katman 1-7 hattında 5 hostta kaynak çıktısıyla
karşılaştırır, Luau/5.2/5.3 sözdizimini elle hesaplanmış beklenen çıktıyla
doğrular, yeniden derlemenin bayt düzeyinde aynı olduğunu ve 364 satırlık
düzleştirilmiş programın 14 589 komuta 111 ms'de indiğini ölçer. Test
koşucusu `tests/vmref.lua` yalnız kabul içindir; M8 O(1) handler tablosunu
üretir.

M8 notu: `vmgen.randomize` 1..255 anahtar uzayını Fisher-Yates ile permüte
eder, 80 opcode adına ilk 80 anahtarı verir, sonraki 160'ı decoy olarak ayırır;
kalan 15 anahtar hiç kullanılmaz. Eşleme seed'e bağlıdır, aynı seed aynı planı
üretir. Her komut `{key,a,b,c,d}` beşlisine kodlanır; `a/b/c/d` alanları
birebir korunur ve hiçbir komut decoy anahtarı taşımaz. `vmgen.emit` tek dosya
üretir: yardımcılar (53-bit `BW/BN/SHL/SHR`), proto tablosu, `H`, `X`
dispatcher'ı, 240 handler ataması ve giriş closure'ı. Tüm handler'lar tek
imzayı paylaşır; kontrol handler'ları `pc` döndürür, diğerlerine emit sırasında
`return pc+1` eklenir. `CLOSURE` handler'ı closure fabrikasını upvalue olarak
görsün diye `local X,F` handler'lardan önce bildirilir; handler'lar `W`'den
önce kurulur. Decoy gövdeleri 24 zararsız şablondan build başına karıştırılarak
seçilir; hiçbiri hata üretmez, yalnız yerel/`R[a]`/`S.top` üzerinde sıfır
etkili işlem yapar. Üretilen metin Lua 5.1 alt kümesidir: `elseif`, `goto`,
`//`, bit operandları yoktur; ortam `_ENV or getfenv()` ile alınır. Runtime
adları (`H,P,E,X,F,W,SU,PK,...`), handler sırası ve decoy eşlemesi seed'den
türetilir; 10 seed 10 farklı dosya üretir. Kabul testi plan/anahtar/komut
kodlamasını, kaynak şeklini (240 handler, tek dispatch, `elseif` yok), 7 elle
kurulmuş ISA programını (NOP/CLOSE/SETTOP/BAND..SHR/TEST/TESTSET/TESTNIL/
VARARG/SETLIST/hücre), 29 programlık corpus'u kaynak, `tests/vmref.lua` ve
üretilen runtime ile 5 hostta karşılaştırır; decoy komutlarını programın başına
ve sonuna enjekte ederek etkisizliğini, sıfır-decoy build'ini ve 364 satırlık
programın 224 700 B / 15 ms'de üretildiğini doğrular. Performans örneği
(`MODULE8_PERF`) yalnız raporlanır; 3× bütçesi M12'de tam hat üzerinde ölçülür.

M9 notu: `bytecode.pack` planı tek bir varint akışına indirir (proto sayısı;
proto başına parametre, vararg, komut sayısı, beş alanlı komutlar, sabitler,
upvalue tanımlayıcıları); sabitler etiketlidir (nil, false, true, sayı metni,
string, ±sonsuz, NaN). Gövde 64 baytlık bloklara sıfırla doldurulup RFC 8439
ChaCha20 sayaç modunda şifrelenir; anahtar gömülü anahtardan ve dolgulu gövde
uzunluğundan türetilen oturum anahtarıdır, nonce üç kelimesi oturum anahtarı
etiketini, düz metin uzunluğunu ve dolgulu gövde uzunluğunu bağlar. Başlık 16
bayttır: şifreli gövdenin FNV-1a32 sağlama toplamı, düz metin uzunluğu, dört
anahtar baytının SipHash-2-4 32-bit etiketi, sürüm 9 ve anahtar etiketinden
türeyen dört işaret baytı; tüm alanlar LE. SipHash-2-4 64-bit durumu dört
(hi, lo) 32-bit kelime olarak taşır ve özet 32 bite katlanır; gövde sağlama
toplamı hız için FNV-1a kalır. Şifreleme build tarafında yapıldığından,
gerçek bit operatörü olan hostlarda (5.3/5.4) permütasyon `load` ile derlenen
tamsayı hızlı yoluna düşer; 5.1/Luau ve 32-bit tamsayılı hostlar tablo tabanlı
aritmetik yolda kalır. İki yol birebir aynı keystream'i üretir, dolayısıyla
paket çıktısı bayt bayt aynıdır; hızlı yol 2000 stringlik build'de ChaCha
aşamasını 0.73 s'den 0.27 s'ye indirir. Anahtar
seed'den türetilir ve dosyada görünmez: emitter anahtarı `(p1*p2+p3)%2^32`
ifadesiyle yeniden kurar. Komutun `d` alanı etiketli taşınır: 0 tamsayı varint,
3/5/6/7 sayı metni; çünkü `1.0`/`-0.0` gibi float immediate'ların alt tipi
korunmalıdır ve 2^52 üstü tamsayılarda zigzag ikiye katlama ile varint
birikimi 5.1/5.2'nin 53-bit kesin aralığını aşar. Benzer biçimde 5.3+ tamsayı
sabitleri `tostring` ile, float'lar `%.17g` + gerekirse `.0` ile yazılır;
`unzigzag` `floor` kullanır ki 5.3/5.4'te tamsayı alt tipi ve `tostring`
çıktısı kaynakla birebir kalsın (düz `/` float üretirdi). Emit edilen runtime
başlığı doğrular (uzunluk, sürüm/işaret, sağlama toplamı, anahtar etiketi) ve
ancak ondan sonra çözer; çözücü `vmgen` içinde `bytecode.lua` yardımcılarının
birebir kopyasıdır ve geçici `D/B/O/BK/HD` tamponlarını `nil`'ler. Tüm tur
aritmetiği float alanında tutulur (`0.0` ve `.0` çarpanları): `lua_Integer`'ı
32 bit olan hostlarda (Fengari) tam sayı çarpımı 2^31'de sarar, float çarpımı
2^53'e kadar tamdır; böylece tarayıcı şifreli metni native ile aynıdır. Sayaç
modu olduğu için tek baytlık düz metin değişimi yalnız o baytı değiştirir.
`bytecode.generate` randomize→pack→emit kısayoludur.
Kabul testi başlık alanlarını, 15 proto/1113 komutluk planın bayt düzeyinde
geri dönüşünü (tüm sabit etiketleri, ±0, ±sonsuz, NaN, 2^52 üstü tamsayı,
float komut operandı), 7 unpack + 4 runtime + 1 yanlış anahtar tamper vakasını,
payload ve kaynakta kaynak stringi/sayı metni/opcode adı/anahtar literali
bulunmadığını, RFC 8439 §2.3.2 anahtar akışı vektörünü, 1..40 baytlık
encrypt/decrypt turunu, sıfır dolgu yoğunluğunu, tek bayt yayılımını, anahtar
avalanche'ını, uzunluk/anahtar bağlanmasını ve 10/10 polimorfizme (blob,
kaynak, anahtar) bakar; 300 satırlık
program 1919 komuta iner ve 12 676 B blob'a paketlenir (pack 13 ms, emit 4-9
ms), üretilen runtime kaynakla aynı çıktıyı verir.

M10 notu: `selfmod.apply` randomize edilmiş planı emitter'dan önce işler ve her
proto'nun komut listesini 4 komutluk bloklara böler. Blok düzeni 4 baytlık LE
durum öneki + anahtar akışı XOR'lu gövdedir; gövde `FNV-1a32(payload)` ile
başlar, ardından komutların varint akışı gelir. Anahtar akışı ana anahtar, proto
indeksi, blok indeksi, 32-bit durum (16-bit yarılar hâlinde karıştırılır) ve
zincir değerinden türetilir; zincir değeri önceki bloğun build zamanındaki
şifreli baytlarının FNV-1a32'sidir, dolayısıyla bloklar sıraya bağlıdır ve
takas/bozma iç sağlama toplamında yakalanır. Runtime yalnız çalışmak üzere
olduğu bloğu çözer; canlı pencere ham `max(1, min(64, floor(0.2*T/B)))*B`
komuttur, sonra 256 komutluk tabana yükseltilir ve `MAX_BLOCKS*BLOCK = 256`
tavanına indirilir (`WINDOW_FLOOR=256`, `MAX_BLOCKS=64`); taban hiçbir zaman
proto'nun kendisini aşmaz. Pratikte pencere `min(total, 256)`'dır; `%20`
kuralı yalnız tavan 1 280 kelimenin üstüne çıkarılırsa bağlar. Gerekçe
ölçümdür: bir proto her çağrıda bütün gövdesini dolaştığı için penceresi
gövdeden küçükse aynı bloklar her çağrıda yeniden çözülür. 2 000 çağrılık
küçük fonksiyon %20 pencerede 3,2 s, 256 tabanda 37 ms sürdü (selfmod'suz 35
ms); eski 64 komutluk taban ~400 komutluk düzleştirilmiş gövdede hâlâ her
çağrıda çözüyordu. Büyük proto'larda pencere dolunca en eski
blok önce yeni bir durumla yerinde yeniden şifrelenir, sonra düşürülür; böylece
çalışma sırasında depodaki baytlar sürekli değişir ve geri atlayan dallar
bloğu yeniden çözebilir. M9 paketi bu depoyu proto başına `sm=1, B, cap,
toplam, blok sayısı` başlığı ve `(zincir, uzunluk, blok)` üçlüleriyle taşır;
komut listesi plan üzerinde boşaltılır (`P.c={}`), böylece düz tablo hiçbir
aşamada emitter'a ulaşmaz. 5.1/5.2 uyumu için tüm karıştırma işlemleri 2^53
altında kalır (`//`, bit operatörü, `string.pack` yok). `selfmod.replay` kabul
testi için aynı FIFO çöz/çıkar/yeniden şifrele döngüsünü planın kopyasında
koşturur. Kabul testi blok bölme ve canlı pencere formülünü (taban ve tavan
dahil), 409+11 komutluk zorlu planın (float operand, -0.0, NaN, 2^52 üstü
tamsayı, pencere tabanını aşan dolgu) blok blok geri dönüşünü,
gövde/durum/zincir/kesik blok tamperini, iki bağımsız yükleyicinin (yardımcı
ve elle simülasyon) aynı kararı verdiğini ve yeniden şifrelenen blokların
tekrar çözülebildiğini, tekrar eden komutlarda blokların yine de farklı
çıktığını, paket sonrası `sm` metadata'sının korunduğunu, 14/14 corpus
eşleşmesini, 3 runtime tamper vakasını (bozuk blok, bozuk zincir, takas — M9
dış sağlama toplamı yeniden hesaplandığı hâlde), 10/10 polimorfizmi ve 300
satırlık programın 1919 komut / 480 blok / 256 komut canlı pencereyle
çalıştığını doğrular; derleme 14 ms, pack 34 ms, emit 5 ms, blok deposu
16 289 B, paketli blob 19 172 B, kaynak 92 856 B, 416 yerinde yeniden şifreleme.

M11 notu: `antidebug.plan` tohumdan bir prob maskesi, ağırlık tablosu ve sıra
üretir; hook biti her zaman açıktır ve ağırlığı 2'dir, zayıf probların ağırlığı
1 veya 2 olabilir, eşik sabit 2'dir. RNG'nin yüksek yarısı kullanılır: LCG'nin
alt biti her adımda döndüğü için eski düşük-bit çekilişi tohumdan bağımsız
olarak yalnız iki maske üretiyordu; düzeltmeden sonra 20 tohum 19 farklı set
veriyor. `Antidebug.prologue` bu kararı `ADT` sayacına yazar, sonda
`ADT>=2` ise 1'e indirir; `Antidebug.probe` aynı aritmetiği build tarafında
yansıtır, böylece kabul testi emisyon ve referans kararını bayt bayt
karşılaştırır. `what` probu `what=="Lua"` bekler (PUC Lua'nın bildirdiği değer;
eski `"L"` karşılaştırması temiz hostta da tetikleniyordu) ve `linedefined>=0`
ister. Sapma tarafında `VMGen.randomize` sayısal komutlardan güvenli sabit
listesini türetir: yalnız `LOADK` ile yüklenen ve anahtar olarak kullanılmayan
(`GETGLOBAL`/`SETGLOBAL`/`GETFIELD`/`SETFIELD`/`SELF` dışı) string'ler;
`Antidebug.deviation` bu indeksleri gömüp `string.byte`/`char` ile yalnız
harfleri döndürür (büyük/küçük korunur, z→a). Sayılar, bool/nil ve global/alan
adları dokunulmaz. M6 havuzunda başlık baytları (anahtar/şifreli metin/blob
uzunlukları) asla döndürülmez; sapma yalnız giriş başına şifreli blob aralığını
döndürür ve her bayt kaydırılır (yalnız harf değil: kısa XOR blob'unda hiç harf
yoktu, harf-döndürme o sabitleri olduğu gibi bırakıyordu). Alan adları
(`ast.fieldKeys`) ve trap canary girişleri (`ast.canaryKeys`) aralığın dışında
tutulur: bozuk bir alan adı nil üyeye dönüşür, bozuk canary ise çözücünün tamper
bayrağını açar ve o bayrak her çözülen değeri bir bayt kaydırdığı için alan
adları da çöpe gider. Executor host'unda (`getgenv`/`gethui`/
`identifyexecutor`/`hookfunction`) belirsiz problar 0 ağırlığa düşer, sağlıklı
bir executor oturumu bu yüzden sapmaz. Executor kapısı `getgenv` yoksa ve
`game` bir DataModel değilse chunk'ı sessizce durdurur, yani website runner'ı
hiçbir şey yazdırmaz. `emit` giriş çağrısını `pcall` zarfına alır; zarf artık
sadece yutmakla kalmaz: sapmış çalıştırma bir API string'i yüzünden hata
verirse (bozuk `GetService` adı, `"%d"` formatı, `select("#")`), `ADRST`
orijinal sabitleri (interned string referansları) geri koyar ve program temiz
runtime'da yeniden koşar — hook'lu oturum boş sonuç yerine normal çıktı üretir.
Kabul
testi prob planını (determinizm, hook zorunluluğu, ≥8 farklı set), referans
probu (temiz host 0 puan, canlı hook her seed'de eşik üstü, kapalı problar
katkısız, eksik `debug`/`string` nötr), 14 programlık corpus'u hem temiz hem
hook'lu çalıştırmayı, gerçek `debug.sethook` cihazını (hata yok, çıktı sapıyor,
hook kurulu kalıyor), çıktıda `os.exit`/`debugger`/`sethook` bulunmadığını,
host global'lerinin değişmediğini, M9/M10 entegrasyonunu ve paketsiz yolu,
istatistik alanlarını, 10/10 polimorfizmi ve 300 satırlık programı kapsar.
300 satır → 144 246 B kaynak, build ~85 ms, yükleme prob yükü < 1 ms; hook'lu
çıktı 34 baytlık metnin 28 baytında sapar. 5.1'de eksi sıfır ayrı kaynakla
doğrulanır: 5.1 parser'ı sonraki `-0.0` literalini mevcut `+0` sabitiyle
birleştirdiği için aynı chunk'ta `0` yazmak kaynakta da işareti düşürür.

M12 notu: `integrity.plan` SipHash-2-4 tabanlı, M9'un başlık etiketinden ayrı
durum ve salt'la anahtarlanan bağımsız bir hash ailesi kurar (bu yüzden M9'un
FNV gövde checksum'ını yeniden hesaplamak yetmez), 3001..4800 arası
kontrol periyodu, **üç** 12..20 karakterlik canary, altı kontrol noktası ve
2^31 altı salt üretir; salt'tan türeyen iki 32-bit anahtar SipHash'e verilir.
Her canary iki parça hâlinde gömülür (`"önek".."son"`). Tüm
aritmetik 16-bit bölünmüş çarpımla 2^53 altında kalır, 32-bit sabitler
`(a+b)%4294967296` olarak bölünür. `Integrity.prologue`
yükleme anında paket blobunun tamamını aynı SipHash ailesiyle hash'ler; blob
128 KiB'ı aştığında doğrusal maliyet için FNV-1a ikili yoluna (`IB`) düşer —
yine M9'dan bağımsız sabit ve salt ile. Çalışma sırasında her `period`
dispatch'te altı kontrol noktasından biri döner: canary metni + SipHash'i +
uzunluğu, yuvarlanan zincir (`c=(c*1664525+özet+uzunluk+i*2654435761+
1013904223)%2^32`, döngü sonunda `chain0`'a sıfırlanır) ve iki örneklenmiş
handler anahtarı (`type()=="function"` ve `H[k]==HB[k]`) birlikte doğrulanır.
İlk döngünün son noktasında `pairs(HB)` ile bir kerelik tam tablo denetimi
çalışır; giriş sayısı beklenen toplamla karşılaştırılır. M11'in geç-hook
mandalı (`ADH>=2`) aynı tick'te başarısızlık koşuluna eklenir. Durum tek `IZ`
tablosunda tutulur (Luau 200 register sınırı). Her tick'in sıcak yolu tek
toplama + tek karşılaştırmadır.
Her başarısızlık yolu tek ve aynı iki ifadedir: nil indekslemesi; mesaj
`"attempt to index a nil value"`, ekrana hiçbir şey basılmaz, `os.exit`
çağrılmaz, yardımcı global'e yazılmaz. `obfuscate.run` M1→M6 AST geçişlerini,
M7 derlemeyi, M8 randomize'ı, M10 selfmod'u, M9 pack'i ve M8 emit'i (M11/M12
prologue'larıyla) tek çağrıda yürütür; istatistikte payload/plain/instruction/
selfmod/antidebug/integrity alanlarını döndürür. `autofix.run` aynı çıktıyı
sandbox'ta kaynağa karşı doğrular ve `strong → normal → fast → minimal`
merdiveniyle düşer; `verify` çıktı, dönüş değerleri ve hata mesajını
karşılaştırır. CLI (`src/cli.lua`) `--preset/--seed/--run/--auto-fix/--stats/
--max-steps/--seconds/-o` kabul eder; çıkış kodları 0/1/2/3'tür ve `--stats`
katman sayaçlarını basar. Kabul testi integrity planını, canary/blob/handler
tamperini, hook'lu hostta sessiz sapmayı, sandbox izolasyonunu (sıralı çıktı
yakalama, `io.open`/`os.exit` engeli, adım limiti, deterministik `_ENV`),
karşılaştırıcıyı, onarım merdivenini (ilk denemede başarı, compile hatasında
tırmanış, tükenme, fatal parse'da durma), CLI argüman/çıkış kodlarını ve dosya
yazımını, 5 seed'de 5 farklı çıktıyı ve 302 satırlık programı kapsar
(860 974 B, 773 ms; tüm 5 hostta PASS).

## Web konsolu

`web/build12.py` `index.html`'i tek dosya olarak üretir: fengari-web
(Lua 5.3, JS) + 16 modül + `web/v2driver.lua` base64/inline edilir. Sayfa
`__ACTION` (`build`/`run`/`fix`), `__SRC`, `__CODE`, `__PRESET`, `__SEED`,
`__MAXSTEPS` ve `__SECONDS` değişkenlerini kurup driver chunk'ını çalıştırır;
sonuç `status \1 length \1 percent-encoded JSON \1 "" \1 ""` çerçevesiyle
döner (JSON string'leri yüzde-kodlu, saf ASCII). Arayüz antilua tarzı
siyah/kırmızı konsoldur: girdi + tek "Obfuscate" düğmesi (güç seçimi
varsayılan **En güçlü**), **Rules** bölümü (8 toggle: flatten, opaque,
selfmod, antidebug, integrity, executor, gethui, antiwebhook — ilk beşi
preset'ten, executor açık, gethui/antiwebhook kapalı gelir), çıktı paneli
(kopyala/indir + boyut/prototip/opcode/entegrite/süre), çalıştırma/onarım
paneli (kaynak ve obfuscated çıktı yan yana, "doğrulandı" rozeti, Çalıştır ve
Otomatik onar) ve **Araçlar** bölümü. Ağ etiketi "yerel · ağ gerekmez"tir
(çıktı tamamen çevrimdışı üretilir, ağ çağrısı yok).

Araçlar bölümü dört karttır:
- **Loadstring dönüştürücü**: obfuscated çıktıyı `loadstring(<quoted>)()`
  veya `loadstring(game:HttpGet(<url>))()` biçimine sarar; kopyala düğmeli.
  `luaQuote` tüm kontrol/basılı olmayan baytları `\ddd` olarak kaçar.
- **200-register bypass**: kaynağı `fast` preset + tüm rules kapalıyla
  VM'e indirir; register-array VM'i Lua'nın 200-local sınırını aşar (230
  local'lik kaynak → tam çıktı). Çıktı sandbox'ta doğrulanır; kaynak zaten
  200-local limitini aşıyorsa referans koşamaz, not bunu dürüstçe belirtir
  ("kaynak sandbox limitini aştığı için karşılaştırılamadı"), çıktı yine de
  tam ve doğrudur.
- **Deobfuscator**: `string.char`/`("\0").char`/hex argümanlı char katlama,
  kaçışlı literal çözme (`\ddd`/`\xHH`/`\z`), `string.rep` + `:rep` +
  `:reverse` katlama, `table.concat({..})` birleştirme, saf-sayı aritmetik
  eval ve literal-concat birleştirme yapan derin statik temizleyici.
- **Dumper**: yapıştırılan çıktıyı **çalıştırmadan** tarar; char/byte
  tabloları, kaçışlı literal'ler, base64, `\xHH` hex blob'ları ve tek-byte
  XOR (harf/boşluk yoğunluğu puanlamasıyla 1..255 anahtar) katmanlarını açar.
  Bulguları satır numarası + kısaltılmış önizlemeyle raporlar; VM gibi yalnız
  çalışma anında çözülen gövdelerde hiçbir şey uydurmaz, bunu açıkça yazar.

Fengari uyumluluğu (ölçülen farklar):
- `%` işleci tamsayı işlenenlerde float alt tipi döndürür; driver `math.floor`
  sonucunu `math.tointeger` ile daraltır, yoksa doğru program `55.0` basardı.
- `io` kütüphanesi yoktur; sandbox `io` yokluğunu boş tabloyla karşılar.
- Fengari yerliden ~20-30× yavaştır; strong doğrulama 300 satırda ~1.7 s,
  yerlide ~95 ms sürer.
- M6 çözücüsü AST'ye enjekte edilip VM bytecode'una derlendiği için yerel
  bit operatörüyle hızlandırılamaz; maliyet VM dispatch'inde kalır.
- M10 canlı pencere tabanı (256 komut) bu ortamda ölçüldü: 29 satırlık örnekte
  strong uçtan uca doğrulama 1.81 s → 0.64 s, build 0.49 s; 2 000 çağrılık
  fonksiyonda 3.2 s → 37 ms.

## Risk kaydı

| Risk | Etki | Karşılık |
| --- | --- | --- |
| Handler çağrısı 3× bütçesini aşar | Performans hedefi | Süper-komut birleştirme + sıcak döngü kısaltma |
| Feistel maliyeti büyük stringlerde yüksek | Build/runtime | Şema seçimi boyuta göre; küçük stringlerde XOR |
| Flatten + VM çift dispatch | Performans | Flatten çıktısı jump tabanlı bytecode'a indirgenir; sıcak döngü gövdeleri `minStatements` eşiğiyle korunur |
| M10 sıcak döngüde blok yeniden şifrelemesi | Performans | Canlı pencere `min(total,256)`; blok 4 komut, çıkarma başına tek FNV + XOR turu; 2 000 çağrılık gövdede ek yük 3.2 s → 37 ms (selfmod'suz 35 ms) |
| Fengari `%` float alt tipi | Yanlış çıktı | Driver `math.floor` sonucunu `math.tointeger` ile daraltır; native ve tarayıcı çıktısı birebir |
| Autofix daha zayıf preset'e düşürür | Güvenlik | Merdiven yalnız gerçek uyuşmazlıkta tırmanır; parse/scope fatal'dır, sonuç ve deneme listesi raporlanır; `minimal` bile şifreleme + integrity bırakır |
| Hesaplama ağırlıklı kodda VM yavaşlığı | Hedeflenen 3× aşılıyor | Saf-Lua dispatch VM'in bilinen sınırı: 802 satır/10 000 çağrı benchmark'ında ham 2 ms, strong 2 265 ms (~1 130×). C çağrısı ağırlıklı gerçek iş yüklerinde oran düşer; build ve bellek bütçeleri tutulur. Hız önceliği için `fast` preset'i var |
| M11 probları açık kodda okunabilir | Tersine mühendislik | Zayıf prob seçimi/ağırlığı/sırası seed'den; eşik 2 ve hook ağırlığı 2 sabit; problar salt okunur, yama kolay ama tespit çökmediği için fark edilmesi zor |
| M11 sapması yalnız değer string'lerini bozar | Tespit gücü | Sayısal programlar etkilenmez (bilinçli güvenli taraf); komut akışı ve yapısal sabitler korunur, giriş `pcall` zarfında; M12 integrity katmanı ek koruma sağlar |
| Compact çıktı dökümünde okunur VM gövdesi | Tersine mühendislik | Mühür: LZSS + konum-bağımlı akış şifresi + 91 sembol base91 + dolgu + yük FNV-1a32 checksum; gövde tek bracket string; çözücü `local`siz durum makinesi (tohumlu alan adları, bayt-kodlu ortam anahtarları, `dump`/`gethook`/`char` kimlik denetimi döngüde tekrar, chaff okumalar, çağrı öncesi alan temizliği); blob/alfabe/anahtar `__call` içinde saklanır, `setmetatable` boş tablo alır; hiçbir yerde `getfenv` çağrılmaz (v1 motoru dahil, ortam `_ENV` → `_G`); çözülmüş metin yalnız yükleme anında; yükleme öncesi `load` hook'u istemci tarafında kapatılamaz |
| NaN ile opaque predicate yanlış | Semantik | Predicate'ler yalnız üretilen tamsayı değişkenlerle |
| Luau tip sözdizimi kenar durumları | Parse hatası | M1 corpus'unda regresyon testi |

2026-11-13 executor "attempt" regresyonu ve düzeltmesi (kullanıcı raporu):
Yayınlanan tüm çıktılar bazı executor'larda `attempt to ...` hatasıyla ölüyordu.
Dört ayrı kaynak bulundu ve kapatıldı; hiçbiri şifreleme katmanlarıyla ilgili
değil, ortam edinme yollarındaki korumasız çağrılardı:

1. **v1/compact `N.E`** eski satırı `_G.<rastgele-ad>` üzerinden korunuyordu ama
   o ad hiçbir globalde yok, dolayısıyla her çalıştırmada `getfenv(1)`
   korumasız çağrılıyordu. Kısıtlı `getfenv` sunan hostta ölümcül, ayrıca env
   logunda iz bırakıyordu. Yeni sıra: `_ENV` → `_G` (standart kütüphane varsa,
   yani 5.1) → `getgenv` (rawget + pcall) → `getfenv(1)` (rawget + pcall) → `_G`.
   Hiçbir adım hata fırlatmıyor; Roblox'ta `_G` kütüphane taşımadığı için
   sıradaki adım devreye giriyor.
2. **v1 anti-debug gate** `game` tablo değilse (Roblox'ta `game` userdata'dır)
   `debug.gethook` sonucuna bakıp sahte `attempt to index a nil value`
   fırlatıyordu. Executor'ların kendi hook'ları sağlıklı istemde de vardır;
   bu yüzden yanlış pozitif. Prob artık yalnız yerel bir bayrak (`N.dk`) yazıyor,
   programa hiçbir şey yansımıyor. İlk gate de `getgenv`/`getfenv` yoksa
   çalışıyor (gerçek Roblox-dışı host) ve `N.E` tablo denetimiyle korunuyor.
3. **`Big.header`** (split yolu) `getfenv and getfenv()` diyordu: kısıtlı
   `getfenv`'te tüm parçalı çıktı yüklemede ölürdü. Şimdi `type` + `pcall`
   ile alınıyor, `setmetatable` pcall'lanıyor, `setfenv` yoksa parçalar chunk
   ortamında çalışıyor.
4. **Seal stub** yolu: `envfix` içindeki `getfenv()` (önceki geçişte kapatıldı)
   ve `os.clock` probe'u (`t0`) korumasızdı; CPU tripwire için ilk ölçüm artık
   pcall içinde, hata verirse `P.clk=nil` olup tick karşılaştırması atlanıyor.

Doğrulama (Luau, executor şeklinde sandbox; `getgenv`/`getfenv`/`setfenv`
kopyalanmış global tabloya bağlı): compact, tek parça v2 (game10) ve 360 KB
parçalı build aynı 8 modda çalıştı — normal, `getfenv` yok, `getfenv` kısıtlı,
`setfenv` yok, dondurulmuş `_G`, `os.clock` kısıtlı, `debug` kısıtlı, kurulu
hook + `game` tablo değil. Hepsi `RUN OK`. Ayrıca v1 suite 5 host + Luau PASS,
v2 12×5 matris 60/60 PASS, `print("h")` compact 12 586 B, game10 1 616 839 B
(Luau'da çıktı kaynakla aynı), v1big 4 858 468 B / 3 parça, tarayıcıda build
"✓ executed · output matched".
