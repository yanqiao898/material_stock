import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '起重工具进销存',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ========== 数据库工具 ==========
class DBHelper {
  static Database? _db;
  static Future get db async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), "stock.db");
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE product (
          barcode TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          spec TEXT,
          cost REAL,
          price REAL,
          stock REAL DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE stock_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          barcode TEXT,
          type TEXT,
          num REAL,
          remark TEXT,
          create_at TEXT
        )''');
        await db.execute('''CREATE TABLE sale_order (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          order_no TEXT UNIQUE,
          create_at TEXT,
          total REAL,
          remark TEXT
        )''');
        await db.execute('''CREATE TABLE sale_item (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          order_no TEXT,
          barcode TEXT,
          name TEXT,
          spec TEXT,
          price REAL,
          num REAL,
          subtotal REAL
        )''');
      },
    );
    return _db!;
  }

  static Future<Map<String, dynamic>?> getProduct(String bc) async {
    final res = await (await db).query("product", where: "barcode=?", whereArgs: [bc]);
    return res.isNotEmpty ? res.first : null;
  }

  static Future addProduct(Map<String, dynamic> p) async {
    await (await db).insert("product", p, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future stockIn(String bc, double num, String remark) async {
    final d = await db;
    await d.rawUpdate("UPDATE product SET stock=stock+? WHERE barcode=?", [num, bc]);
    await d.insert("stock_log", {
      "barcode": bc,
      "type": "in",
      "num": num,
      "remark": remark,
      "create_at": DateTime.now().toIso8601String(),
    });
  }

  static Future stockOut(String bc, double num, String remark) async {
    final d = await db;
    await d.rawUpdate("UPDATE product SET stock=stock-? WHERE barcode=?", [num, bc]);
    await d.insert("stock_log", {
      "barcode": bc,
      "type": "out",
      "num": num,
      "remark": remark,
      "create_at": DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getAllProducts() async {
    return (await db).query("product", orderBy: "name ASC");
  }

  static Future<List<Map<String, dynamic>>> getStockLogs(
      {String? barcode, int limit = 100}) async {
    if (barcode != null) {
      return (await db).query("stock_log",
          where: "barcode=?", whereArgs: [barcode],
          orderBy: "create_at DESC", limit: limit);
    }
    return (await db).query("stock_log",
        orderBy: "create_at DESC", limit: limit);
  }

  static Future saveSaleOrder(String orderNo, double total, String remark,
      List<Map<String, dynamic>> items) async {
    final d = await db;
    await d.insert("sale_order", {
      "order_no": orderNo,
      "create_at": DateTime.now().toIso8601String(),
      "total": total,
      "remark": remark,
    });
    for (var item in items) {
      await d.insert("sale_item", {
        "order_no": orderNo,
        "barcode": item["barcode"],
        "name": item["name"],
        "spec": item["spec"],
        "price": item["price"],
        "num": item["num"],
        "subtotal": item["subtotal"],
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getSaleOrders(
      {int limit = 50}) async {
    return (await db).query("sale_order",
        orderBy: "create_at DESC", limit: limit);
  }
}

// ========== 蓝牙打印 ==========
class BluetoothPrinter {
  static FlutterBluePlus blue = FlutterBluePlus();
  static BluetoothDevice? _device;

  static Future<List<BluetoothDevice>> scanDevices({int timeoutSec = 10}) async {
    final devices = <BluetoothDevice>[];
    blue.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.name.toString().contains('ESC') ||
            r.device.name.toString().contains('POS') ||
            r.device.name.toString().contains('printer') ||
            r.device.name.toString().contains('Printer') ||
            r.device.name.contains('蓝牙') ||
            r.device.name.contains('打印')) {
          if (!devices.contains(r.device)) devices.add(r.device);
        }
      }
    });
    await blue.startScan(timeout: Duration(seconds: timeoutSec));
    await Future.delayed(Duration(seconds: timeoutSec));
    await blue.stopScan();
    return devices;
  }

  static Future<bool> connect(String name) async {
    final devices = await blue.connectedDevices;
    for (var d in devices) {
      if (d.name.contains(name)) {
        _device = d;
        return true;
      }
    }
    return false;
  }

  static Future<bool> printReceipt(String orderNo, List<Map<String, dynamic>> cart,
      double total, String remark) async {
    try {
      // Try to connect to printer
      final devices = await blue.connectedDevices;
      BluetoothDevice? printer;
      for (var d in devices) {
        if (d.name.toString().contains('ESC') ||
            d.name.toString().contains('POS') ||
            d.name.toString().contains('printer') ||
            d.name.toString().contains('打印')) {
          printer = d;
          break;
        }
      }
      if (printer == null && devices.isNotEmpty) printer = devices[0];
      if (printer == null) return false;

      final profile = await ProfileSelector.selectProfile(
          printer.platformChannel);
      final generator = Generator(profile, printer.platformChannel);

      await generator.reset();
      await generator.feed(2);
      await generator.set(align: PosAlign.center);
      await generator.boldOn();
      await generator.text('起重工具进销存', style: PosTextSize.large);
      await generator.boldOff();
      await generator.text('销售小票', size: PosTextSize.doubleHeight);
      await generator.hr();
      await generator.set(align: PosAlign.left);
      await generator.text('单号: $orderNo');
      await generator.text('时间: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
      if (remark.isNotEmpty) {
        await generator.text('备注: $remark');
      }
      await generator.hr();
      await generator.text('商品',
          styles: PosStyles.bold);
      await generator.text('单价  数量  小计',
          styles: PosStyles.size(PosTextSize.small));
      await generator.hr();
      for (var item in cart) {
        await generator.text('${item["name"]}');
        await generator.text(
            '  ${item["price"].toStringAsFixed(2)}  x${item["num"]}  ${item["subtotal"].toStringAsFixed(2)}',
            styles: PosTextSize.small);
      }
      await generator.hr();
      await generator.text('合计: ¥${total.toStringAsFixed(2)}',
          styles: PosStyles.bold);
      await generator.feed(3);
      await generator.cut();
      return true;
    } catch (e) {
      debugPrint('打印失败: $e');
      return false;
    }
  }
}

// ========== 主页 ==========
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  final List<String> _tabs = ['库存', '入库', '出库', '开单', '记录'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('起重工具进销存'), centerTitle: true),
      body: IndexedStack(index: _tab, children: const [
        InventoryPage(),
        StockInPage(),
        StockOutPage(),
        SaleOrderPage(),
        RecordsPage(),
      ]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2), label: '库存'),
          BottomNavigationBarItem(icon: Icon(Icons.arrow_downward), label: '入库'),
          BottomNavigationBarItem(icon: Icon(Icons.arrow_upward), label: '出库'),
          BottomNavigationBarItem(icon: Icon(Icons.point_of_sale), label: '开单'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '记录'),
        ],
      ),
    );
  }
}

// ========== 库存页 ==========
class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});
  @override
  State createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  List<Map<String, dynamic>> _products = [];
  String _search = '';
  bool _loading = true;

  Future<void> loadProducts() async {
    final all = await DBHelper.getAllProducts();
    setState(() {
      _products = all;
      _loading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _products.where((p) {
      final match = p['name'].toString().toLowerCase().contains(_search.toLowerCase()) ||
          p['barcode'].toString().contains(_search);
      return match;
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('库存管理')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: TextField(
          decoration: const InputDecoration(
            hintText: '搜索名称或条码...', prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
          onChanged: (v) => setState(() => _search = v),
        )),
        const Divider(height: 1),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : filtered.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.inventory_2, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text('暂无库存', style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StockInPage())),
                        icon: const Icon(Icons.add), label: const Text('扫码入库')),
                  ]))
                : ListView.builder(padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final p = filtered[i];
                      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(child: Text(p['name'][0])),
                            title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('${p['spec'] ?? '-'} | 进价¥${p['cost']?.toStringAsFixed(2) ?? '-'} | 售价¥${p['price']?.toStringAsFixed(2) ?? '-'}'),
                            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Text('${p['stock']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue)),
                              const Text('库存', style: TextStyle(fontSize: 10)),
                            ]),
                            onTap: () => _showProductDetail(p),
                          ));
                    })),
      ]),
    );
  }

  void _showProductDetail(Map<String, dynamic> p) {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) {
      return DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (_, controller) => ListView(controller: controller, padding: const EdgeInsets.all(16), children: [
          Text(p['name'], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const Divider(),
          _infoRow('条码', p['barcode']),
          _infoRow('规格', p['spec'] ?? '-'),
          _infoRow('进价', '¥${p['cost']?.toStringAsFixed(2) ?? '-'}'),
          _infoRow('售价', '¥${p['price']?.toStringAsFixed(2) ?? '-'}'),
          _infoRow('库存', '${p['stock']}'),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: ElevatedButton.icon(onPressed: () async {
              Navigator.pop(context);
              await Navigator.push(context, MaterialPageRoute(builder: (_) => StockInPage(barcode: p['barcode'])));
              loadProducts();
            }, icon: const Icon(Icons.arrow_downward), label: const Text('入库'))),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(onPressed: () async {
              Navigator.pop(context);
              await Navigator.push(context, MaterialPageRoute(builder: (_) => StockOutPage(barcode: p['barcode'])));
              loadProducts();
            }, icon: const Icon(Icons.arrow_upward), label: const Text('出库'))),
          ]),
          const SizedBox(height: 16),
          ElevatedButton.icon(onPressed: () async {
            Navigator.pop(context);
            await DBHelper.stockIn(p['barcode'], p['stock'], '调整清零');
            await DBHelper.stockOut(p['barcode'], p['stock'], '调整清零');
            loadProducts();
          }, icon: const Icon(Icons.refresh), label: const Text('刷新数据'))),
        ]),
      );
    });
  }

  Widget _infoRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.grey))),
        const Text(':', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 16))),
      ]));
}

// ========== 入库页 ==========
class StockInPage extends StatefulWidget {
  final String? barcode;
  const StockInPage({super.key, this.barcode});
  @override
  State createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final bcCtrl = TextEditingController();
  final numCtrl = TextEditingController();
  final remarkCtrl = TextEditingController();
  Map<String, dynamic>? product;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    bcCtrl.text = widget.barcode ?? '';
    if (widget.barcode != null) _loadProduct(widget.barcode!);
  }

  Future<void> _loadProduct(String bc) async {
    setState(() => _loading = true);
    final p = await DBHelper.getProduct(bc);
    setState(() { product = p; _loading = false; });
  }

  Future<void> submit() async {
    final bc = bcCtrl.text.trim();
    if (bc.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入条码'))); return; }
    final num = double.tryParse(numCtrl.text.trim());
    if (num == null || num <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入有效数量'))); return; }
    setState(() => _loading = true);
    await DBHelper.addProduct({"barcode": bc, "name": product?["name"] ?? "未知商品", "spec": product?["spec"],
        "cost": product?["cost"] ?? 0, "price": product?["price"] ?? 0, "stock": 0});
    await DBHelper.stockIn(bc, num, remarkCtrl.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('入库成功 +$num')));
      bcCtrl.clear(); numCtrl.clear(); remarkCtrl.clear(); setState(() { product = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('物料入库')),
      body: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        ListTile(title: Text(product?["name"] ?? "未扫码"), subtitle: Text(bcCtrl.text.isEmpty ? "请扫码或输入条码" : bcCtrl.text),
            trailing: ElevatedButton(onPressed: () async {
              final bc = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanSinglePage()));
              if (bc != null && mounted) {
                bcCtrl.text = bc;
                _loadProduct(bc);
              }
            }, child: const Icon(Icons.qr_code_scanner)),
        ),
        TextField(controller: numCtrl, decoration: const InputDecoration(labelText: "入库数量"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        TextField(controller: remarkCtrl, decoration: const InputDecoration(labelText: "备注")),
        const SizedBox(height: 24),
        ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _loading ? null : submit,
            child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text("确认入库")),
      ])),
    );
  }
}

// ========== 出库页 ==========
class StockOutPage extends StatefulWidget {
  final String? barcode;
  const StockOutPage({super.key, this.barcode});
  @override
  State createState() => _StockOutPageState();
}

class _StockOutPageState extends State<StockOutPage> {
  final bcCtrl = TextEditingController();
  final numCtrl = TextEditingController();
  final remarkCtrl = TextEditingController();
  Map<String, dynamic>? product;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    bcCtrl.text = widget.barcode ?? '';
    if (widget.barcode != null) _loadProduct(widget.barcode!);
  }

  Future<void> _loadProduct(String bc) async {
    setState(() => _loading = true);
    final p = await DBHelper.getProduct(bc);
    setState(() { product = p; _loading = false; });
  }

  Future<void> submit() async {
    final bc = bcCtrl.text.trim();
    if (bc.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入条码'))); return; }
    final num = double.tryParse(numCtrl.text.trim());
    if (num == null || num <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入有效数量'))); return; }
    if (product == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('商品不存在'))); return; }
    // 零库存销售：允许负库存出库
    setState(() => _loading = true);
    await DBHelper.stockOut(bc, num, remarkCtrl.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('出库成功 -$num')));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('物料出库')),
      body: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        ListTile(title: Text(product?["name"] ?? "未扫码"), subtitle: Text(bcCtrl.text.isEmpty ? "请扫码或输入条码" : "${bcCtrl.text} | 库存: ${product?["stock"] ?? 0}"),
            trailing: ElevatedButton(onPressed: () async {
              final bc = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanSinglePage()));
              if (bc != null && mounted) {
                bcCtrl.text = bc;
                _loadProduct(bc);
              }
            }, child: const Icon(Icons.qr_code_scanner)),
        ),
        TextField(controller: numCtrl, decoration: const InputDecoration(labelText: "出库数量"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        TextField(controller: remarkCtrl, decoration: const InputDecoration(labelText: "备注")),
        const SizedBox(height: 24),
        ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _loading ? null : submit,
            child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text("确认出库")),
      ])),
    );
  }
}

// ========== 销售开单页 ==========
class SaleOrderPage extends StatefulWidget {
  const SaleOrderPage({super.key});
  @override
  State createState() => _SaleOrderPageState();
}

class _SaleOrderPageState extends State<SaleOrderPage> {
  List<Map<String, dynamic>> cart = [];
  final remarkCtrl = TextEditingController();

  double get total => cart.fold(0, (sum, e) => sum + (e["subtotal"] as num).toDouble());

  Future<void> scanAddItem() async {
    final bc = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanSinglePage()));
    if (bc == null) return;
    var p = await DBHelper.getProduct(bc);
    if (p == null) {
      if (!mounted) return;
      await showDialog(context: context, builder: (_) => NewProductDialog(barcode: bc, onSave: () {}));
      p = await DBHelper.getProduct(bc);
      if (p == null) return;
    }
    setState(() {
      cart.add({"barcode": bc, "name": p["name"], "spec": p["spec"], "price": p["price"], "num": 1, "subtotal": p["price"]});
    });
  }

  Future<void> submitOrder() async {
    if (cart.isEmpty) return;
    final orderNo = "ORD-${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}";
    // 零库存销售：自动扣减库存（允许负数）
    var zeroStockWarning = false;
    for (var item in cart) {
      var prod = await DBHelper.getProduct(item["barcode"]);
      if (prod != null) {
        var cur = prod["stock"] as num;
        var need = item["num"] as double;
        if (cur < need) zeroStockWarning = true;
        await DBHelper.stockOut(item["barcode"], need, "销售开单");
      } else {
        // 新商品：开单即入库（初始库存为0，销售后为负数）
        await DBHelper.addProduct({"barcode": item["barcode"], "name": item["name"], "spec": item["spec"] ?? "", "cost": 0, "price": item["price"], "stock": 0});
        await DBHelper.stockOut(item["barcode"], item["num"] as double, "销售开单（新商品）");
      }
    }
    await DBHelper.saveSaleOrder(orderNo, total, remarkCtrl.text, cart);
    if (mounted) {
      if (zeroStockWarning) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("警告：存在零库存商品，已允许销售"), backgroundColor: Colors.orange));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("开单成功 " + orderNo)));
      }
      await BluetoothPrinter.printReceipt(orderNo, cart, total, remarkCtrl.text);
    }
    setState(() => cart.clear());
    remarkCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('销售开单')),
      floatingActionButton: FloatingActionButton.extended(onPressed: scanAddItem,
          icon: const Icon(Icons.qr_code_scanner), label: const Text("扫码添加")),
      body: Column(children: [
        Expanded(child: cart.isEmpty
            ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.point_of_sale, size: 80, color: Colors.grey),
                SizedBox(height: 16),
                Text('点击右下角扫码添加商品', style: TextStyle(color: Colors.grey)),
              ]))
            : ListView.builder(padding: const EdgeInsets.all(8), itemCount: cart.length, itemBuilder: (_, i) {
                final it = cart[i];
                return Card(margin: const EdgeInsets.symmetric(vertical: 4), child: ListTile(
                  title: Text(it["name"], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${it["spec"] ?? "-"} | ¥${it["price"]} × ${it["num"]}"),
                  trailing: Text("¥${it["subtotal"].toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  onTap: () => setState(() => cart.removeAt(i)),
                ));
              })),
        if (cart.isNotEmpty)
          Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.grey[100]),
              child: Column(children: [
                TextField(controller: remarkCtrl, decoration: const InputDecoration(labelText: "备注（客户/工程）")),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text("合计：¥${total.toStringAsFixed(2)}", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.blue)),
                  ElevatedButton(style: ElevatedButton.styleFrom backgroundColor: Colors.blue),
                      onPressed: submitOrder, child: const Text("保存 + 打印")),
                ]),
              ])),
      ]),
    );
  }
}

// ========== 新增商品弹窗 ==========
class NewProductDialog extends StatefulWidget {
  final String barcode;
  final VoidCallback onSave;
  const NewProductDialog({super.key, required this.barcode, required this.onSave});
  @override
  State createState() => _NewProductDialogState();
}

class _NewProductDialogState extends State<NewProductDialog> {
  final nameCtrl = TextEditingController();
  final specCtrl = TextEditingController();
  final costCtrl = TextEditingController();
  final priceCtrl = TextEditingController();

  Future<void> save() async {
    await DBHelper.addProduct({
      "barcode": widget.barcode,
      "name": nameCtrl.text.trim(),
      "spec": specCtrl.text.trim(),
      "cost": double.tryParse(costCtrl.text.trim()) ?? 0,
      "price": double.tryParse(priceCtrl.text.trim()) ?? 0,
      "stock": 0,
    });
    if (mounted) Navigator.pop(context);
    widget.onSave();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('新增商品 ${widget.barcode}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "商品名称 *")),
        TextField(controller: specCtrl, decoration: const InputDecoration(labelText: "规格型号")),
        TextField(controller: costCtrl, decoration: const InputDecoration(labelText: "进价"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        TextField(controller: priceCtrl, decoration: const InputDecoration(labelText: "售价"), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
        ElevatedButton(onPressed: save, child: const Text("保存")),
      ],
    );
  }
}

// ========== 记录页 ==========
class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key});
  @override
  State createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  int _tab = 0;
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;

  Future<void> loadData() async {
    setState(() => _loading = true);
    if (_tab == 0) {
      _logs = await DBHelper.getStockLogs(limit: 200);
    } else {
      _orders = await DBHelper.getSaleOrders(limit: 50);
    }
    setState(() => _loading = false);
  }

  @override
  void initState() {
    super.initState();
    loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('操作记录')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: _tabBadge(0, '出入库记录')),
          const SizedBox(width: 8),
          Expanded(child: _tabBadge(1, '销售记录')),
        ])),
        const Divider(height: 1),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _tab == 0 ? _buildLogList() : _buildOrderList()),
      ]),
    );
  }

  Widget _tabBadge(int idx, String label) {
    final active = _tab == idx;
    return Material(color: active ? Colors.blue : Colors.grey[200], borderRadius: BorderRadius.circular(8),
        child: InkWell(borderRadius: BorderRadius.circular(8), onTap: () async { setState(() => _tab = idx); await loadData(); },
            child: Padding(padding: const EdgeInsets.all(12), child: Center(
                child: Text(label, style: TextStyle(color: active ? Colors.white : Colors.grey[700], fontWeight: active ? FontWeight.bold : FontWeight.normal))))));
  }

  Widget _buildLogList() {
    if (_logs.isEmpty) return const Center(child: Text('暂无记录'));
    return ListView.builder(padding: const EdgeInsets.symmetric(vertical: 8), itemCount: _logs.length, itemBuilder: (_, i) {
      final log = _logs[i];
      final isIn = log["type"] == "in";
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: isIn ? Colors.green[100] : Colors.red[100],
                child: Icon(isIn ? Icons.arrow_downward : Icons.arrow_upward, color: isIn ? Colors.green : Colors.red)),
            title: Text(log["barcode"]),
            subtitle: Text("${log["remark"] ?? ''} | ${DateFormat('MM-dd HH:mm').format(DateTime.parse(log["create_at"]))}"),
            trailing: Text("${isIn ? '+' : '-'}${log["num"]}", style: TextStyle(color: isIn ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
          ));
    });
  }

  Widget _buildOrderList() {
    if (_orders.isEmpty) return const Center(child: Text('暂无记录'));
    return ListView.builder(padding: const EdgeInsets.symmetric(vertical: 8), itemCount: _orders.length, itemBuilder: (_, i) {
      final o = _orders[i];
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.blue[100], child: Icon(Icons.receipt_long, color: Colors.blue)),
            title: Text(o["order_no"], style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text("${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse(o["create_at"]))} | ${o["remark"] ?? ''}"),
            trailing: Text("¥${(o["total"] as num).toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ));
    });
  }
}

// ========== 简易扫码页 ==========
class ScanSinglePage extends StatefulWidget {
  const ScanSinglePage({super.key});
  @override
  State createState() => _ScanSinglePageState();
}

class _ScanSinglePageState extends State<ScanSinglePage> {
  final MobileScannerController ctrl = MobileScannerController();
  bool _locked = false;

  void _onDetect(BarcodeCapture cap) {
    if (_locked) return;
    _locked = true;
    final bc = cap.barcodes.first.rawValue;
    if (bc != null && mounted) Navigator.pop(context, bc);
    Future.delayed(const Duration(milliseconds: 500), () => _locked = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text("扫码")),
      body: MobileScanner(controller: ctrl, onDetect: _onDetect));

  @override
  void dispose() { ctrl.dispose(); super.dispose(); }
}
