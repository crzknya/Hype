import json, msgpack
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak
from hyperliquid.utils import signing as S

KEY = "0x0123456789012345678901234567890123456789012345678901234567890123"
w = Account.from_key(KEY)
out = {"privateKey": KEY, "address": w.address}
out["keccakEmpty"] = keccak(b"").hex()
out["keccakAbc"] = keccak(b"abc").hex()

def digest(data):
    sm = encode_typed_data(full_message=data)
    return keccak(b"\x19" + sm.version + sm.header + sm.body).hex()

def sig(s): return {"r": "%064x" % int(s["r"],16), "s": "%064x" % int(s["s"],16), "v": s["v"]}

order = S.order_wires_to_order_action([
    S.order_request_to_order_wire({"coin":"ETH","is_buy":True,"sz":0.0147,"limit_px":1670.1,"order_type":{"limit":{"tif":"Gtc"}},"reduce_only":False}, 4),
    S.order_request_to_order_wire({"coin":"ETH","is_buy":False,"sz":0.0147,"limit_px":1800,"order_type":{"trigger":{"triggerPx":1800,"isMarket":True,"tpsl":"tp"}},"reduce_only":True}, 4),
], grouping="normalTpsl")
nonce = 1700000000000
cases = []
def l1(name, action, vault, expires, mainnet):
    h = S.action_hash(action, vault, nonce, expires)
    d = digest(S.l1_payload(S.construct_phantom_agent(h, mainnet)))
    s = sig(S.sign_l1_action(w, action, vault, nonce, expires, mainnet))
    cases.append({"name": name, "msgpack": msgpack.packb(action).hex(), "actionHash": h.hex(), "digest": d,
                  "vault": vault, "expiresAfter": expires, "mainnet": mainnet, "nonce": nonce, **{k:str(v) for k,v in s.items()}})
l1("order", order, None, None, True)
l1("orderVaultTestnet", order, "0x1719884eb866cb12b2287399b15f7db5e7d775ea", None, False)
l1("orderExpires", order, None, 1700000060000, True)
cancel = {"type":"cancel","cancels":[{"a":4,"o":123456789}]}
l1("cancel", cancel, None, None, True)
lev = {"type":"updateLeverage","asset":0,"isCross":True,"leverage":10}
l1("leverage", lev, None, None, True)
twap = {"type":"twapOrder","twap":{"a":1,"b":True,"s":"1.5","r":False,"m":30,"t":True}}
l1("twap", twap, None, None, True)
cl = {"type":"order","orders":[{"a":10107,"b":False,"p":"0.00012345","s":"100000","r":False,"t":{"limit":{"tif":"Ioc"}},"c":"0x00000000000000000000000000000001"}],"grouping":"na"}
l1("spotCloid", cl, None, None, True)
out["l1"] = cases

users = []
def user(name, action, types, ptype, mainnet):
    a = dict(action)
    s = sig(S.sign_user_signed_action(w, a, types, ptype, mainnet))
    d = digest(S.user_signed_payload(ptype, types, a))
    users.append({"name": name, "action": a, "digest": d, **{k:str(v) for k,v in s.items()}})
user("usdSend", {"destination":"0x5e9ee1089755c3435139848e47e6635505d5a13a","amount":"1","time":nonce,"type":"usdSend"}, S.USD_SEND_SIGN_TYPES, "HyperliquidTransaction:UsdSend", True)
user("withdraw", {"destination":"0x5e9ee1089755c3435139848e47e6635505d5a13a","amount":"12.5","time":nonce,"type":"withdraw3"}, S.WITHDRAW_SIGN_TYPES, "HyperliquidTransaction:Withdraw", True)
user("classTransfer", {"type":"usdClassTransfer","amount":"100","toPerp":False,"nonce":nonce}, S.USD_CLASS_TRANSFER_SIGN_TYPES, "HyperliquidTransaction:UsdClassTransfer", False)
user("spotSend", {"destination":"0x5e9ee1089755c3435139848e47e6635505d5a13a","amount":"3","token":"PURR:0xc4bf3f870c0e9465323c0b6ed28096c2","time":nonce,"type":"spotSend"}, S.SPOT_TRANSFER_SIGN_TYPES, "HyperliquidTransaction:SpotSend", True)
user("approveAgent", {"type":"approveAgent","agentAddress":"0x5e9ee1089755c3435139848e47e6635505d5a13a","agentName":"ios","nonce":nonce}, [
            {"name": "hyperliquidChain", "type": "string"},
            {"name": "agentAddress", "type": "address"},
            {"name": "agentName", "type": "string"},
            {"name": "nonce", "type": "uint64"}], "HyperliquidTransaction:ApproveAgent", True)
out["user"] = users
out["wire"] = [[x, S.float_to_wire(x)] for x in [1670.1, 0.0147, 1800.0, 0.00012345, 100000.0, 1e-8, 123.45600, 0.1+0.2]]
print(json.dumps(out, indent=1))
