from uuid import uuid4

def divup(n: int, d: int) -> int:
    return (n + (d - 1)) // d

class PartialAmm:
    def __init__(self, r0: int, r1: int):
        self.id = str(uuid4())[-4:]
        self.r0 = r0
        self.r1 = r1
    
    def quoteBuy0(self, a0: int) -> int:
        if a0 >= self.r0:
            raise RuntimeError(f'a0 ({a0}) >= r0 ({self.r0})')
        k = self.r0 * self.r1
        a1 = divup(k, self.r0 - a0) - self.r1
        return a1
    
    def buy0(self, a0: int) -> int:
        a1 = self.quoteBuy0(a0)
        self.r0 -= a0
        self.r1 += a1
        return a1

    def quoteSell0(self, a0: int) -> int:
        k = self.r0 * self.r1
        a1 = self.r1 - k // (self.r0 + a0)
        if a1 >= self.r1:
            raise RuntimeError(f'a1 ({a1}) >= r1 ({self.r1})')
        return a1
    
    def sell0(self, a0: int) -> int:    
        a1 = self.quoteSell0(a0)
        self.r0 += a0
        self.r1 -= a1 
        return a1

    def donate0(self, a0: int) -> int:
        self.r0 += a0
        return self.price0
    
    @property
    def price0(self) -> int:
        return self.r1 / self.r0

    def __str__(self) -> str:
        return f'<{self.__class__.__name__}:{self.id}> r0={self.r0}, r1={self.r1}, k={self.r0*self.r1}, p={self.price0}'

__all__ = ['ParialAmm']

if __name__ == '__main__':
    from matplotlib import pyplot as plt
    # markets = [
    #     PartialAmm(100, 10),
    #     PartialAmm(1000, 100),
    #     PartialAmm(10000, 1000),
    # ]
    # for i, m in enumerate(markets):
    #     prices = []
    #     for j in range(10):
    #         m.buy0(int(m.r0 * 0.05))
    #         prices.append(m.price0)
    #     print(prices)
    #     plt.plot(list(range(len(prices))), prices, label=f'{i}')
    # plt.legend()
    # plt.show()
    m = PartialAmm(int(1e4), int(1e4))
    print(m)
    # m.buy0(90)
    # print(m)
    # m.sell0(500)
    # print(m)
    m.sell0(1e4)
    print(m)

    