package li.cil.oc.common.tileentity.traits.power

import cpw.mods.fml.common.Optional
import cpw.mods.fml.common.eventhandler.Event
import li.cil.oc.OpenComputers
import li.cil.oc.Settings
import li.cil.oc.common.EventHandler
import li.cil.oc.util.mods.Mods
import net.minecraft.nbt.NBTTagCompound
import net.minecraftforge.common.MinecraftForge
import net.minecraftforge.common.util.ForgeDirection

trait IndustrialCraft2Experimental extends Common with IndustrialCraft2Common {
  private var conversionBuffer = 0.0

  private lazy val useIndustrialCraft2Power = isServer && Mods.IndustrialCraft2.isAvailable

  // ----------------------------------------------------------------------- //

  override def updateEntity() {
    super.updateEntity()
    if (useIndustrialCraft2Power && world.getTotalWorldTime % Settings.get.tickFrequency == 0) {
      updateEnergy()
    }
  }

  @Optional.Method(modid = Mods.IDs.IndustrialCraft2)
  private def updateEnergy() {
    tryAllSides((demand, _) => {
      val result = math.min(demand, conversionBuffer)
      conversionBuffer -= result
      result
    }, Settings.get.ratioIndustrialCraft2)
  }

  override def validate() {
    super.validate()
    if (useIndustrialCraft2Power && !addedToIC2PowerGrid) EventHandler.scheduleIC2Add(this)
  }

  override def invalidate() {
    super.invalidate()
    if (useIndustrialCraft2Power && addedToIC2PowerGrid) removeFromIC2Grid()
  }

  override def onChunkUnload() {
    super.onChunkUnload()
    if (useIndustrialCraft2Power && addedToIC2PowerGrid) removeFromIC2Grid()
  }

  private def removeFromIC2Grid() {
    try MinecraftForge.EVENT_BUS.post(Class.forName("ic2.api.energy.event.EnergyTileUnloadEvent").getConstructor(Class.forName("ic2.api.energy.tile.IEnergyTile")).newInstance(this).asInstanceOf[Event]) catch {
      case t: Throwable => OpenComputers.log.warn("Error removing node from IC2 grid.", t)
    }
    addedToIC2PowerGrid = false
  }

  // ----------------------------------------------------------------------- //

  override def readFromNBT(nbt: NBTTagCompound) {
    super.readFromNBT(nbt)
    conversionBuffer = nbt.getDouble(Settings.namespace + "ic2power")
  }

  override def writeToNBT(nbt: NBTTagCompound) {
    super.writeToNBT(nbt)
    nbt.setDouble(Settings.namespace + "ic2power", conversionBuffer)
  }

  // ----------------------------------------------------------------------- //

  @Optional.Method(modid = Mods.IDs.IndustrialCraft2)
  def getSinkTier: Int = Int.MaxValue

  @Optional.Method(modid = Mods.IDs.IndustrialCraft2)
  def acceptsEnergyFrom(emitter: net.minecraft.tileentity.TileEntity, direction: ForgeDirection): Boolean = Mods.IndustrialCraft2.isAvailable && canConnectPower(direction)

  @Optional.Method(modid = Mods.IDs.IndustrialCraft2)
  def injectEnergy(directionFrom: ForgeDirection, amount: Double, voltage: Double): Double = {
    conversionBuffer += amount
    0.0
  }

  @Optional.Method(modid = Mods.IDs.IndustrialCraft2)
  def getDemandedEnergy: Double = {
    if (!useIndustrialCraft2Power) 0.0
    else if (conversionBuffer < energyThroughput * Settings.get.tickFrequency)
      math.min(ForgeDirection.VALID_DIRECTIONS.map(globalDemand).max, energyThroughput / Settings.get.ratioIndustrialCraft2)
    else 0
  }
}
